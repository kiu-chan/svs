import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:openjpeg_ffi/openjpeg_ffi.dart';

import '../errors.dart';
import '../io/byte_sink.dart';
import '../svs/aperio_tags.dart';
import '../svs/svs_file.dart';
import '../tiff/tiff_types.dart';
import '../tiff/tiff_writer.dart';
import 'image_adjustments.dart';
import 'region_decoder.dart';

/// Tile compression for `exportSvsRegionAsSvs`/`exportSvsRegionAsSvsToFile`
/// to (re-)encode the crop's pyramid with — the same two schemes
/// [SvsLevel]/[SvsFile] can already read back (`svs/svs_file.dart`).
enum SvsExportCompression {
  /// New-style JPEG (TIFF `Compression` 7) — lossy, controlled by that
  /// function's `quality` parameter. The default: fast, universally
  /// supported, matches what most real Aperio slides already use.
  jpeg,

  /// JPEG2000 (TIFF `Compression` 33005), via `openjpeg_ffi`'s `encodeJ2k` —
  /// mathematically lossless by default, or lossy at a chosen ratio via
  /// that function's `jp2kCompressionRatio` parameter; typically a
  /// meaningfully smaller file than JPEG at comparable visual quality,
  /// at the cost of slower encoding. Matches what real Aperio JP2K slides
  /// use.
  jpeg2000,
}

/// How aggressively the streaming functions in this file yield control back
/// to the event loop while building a pyramid — a knob for the tradeoff
/// between UI smoothness (this all runs on the main isolate — tile decoding
/// needs `dart:ui`) and raw throughput. Doesn't change peak RAM, which is
/// already bounded by design (a couple of tile-row bands per level in
/// flight at once, never the whole image) regardless of this setting — for
/// genuine RAM control, prefer a disk-streamed `...ToFile`/`...InPlace`
/// export over an in-memory one.
enum SvsPyramidRebuildEffort {
  /// Cedes extra time to the event loop between every row-band (a short
  /// `Future.delayed`, not just a bare microtask yield) — the smoothest
  /// choice when a foreground UI must stay responsive throughout (e.g. a
  /// whole-slide `rebuildSvsPyramid...` call), at some throughput cost.
  low,

  /// Yields once per row-band via a bare microtask (`Future(() {})`) —
  /// this package's long-standing default behavior.
  balanced,

  /// Yields only every 4th row-band — less overhead, fastest, while still
  /// never fully blocking the event loop for an unbounded stretch.
  high,
}

/// Yields control back to the event loop according to [effort] — called
/// once per row-band by the streaming loops below, so a long-running
/// export/rebuild doesn't starve the UI thread. [bandIndex] is a 0-based
/// count of bands processed so far (across the whole export, not reset per
/// level), used by [SvsPyramidRebuildEffort.high] to skip most yields.
Future<void> _yieldForEffort(
  SvsPyramidRebuildEffort effort,
  int bandIndex,
) async {
  switch (effort) {
    case SvsPyramidRebuildEffort.low:
      await Future.delayed(const Duration(milliseconds: 1));
    case SvsPyramidRebuildEffort.balanced:
      await Future(() {});
    case SvsPyramidRebuildEffort.high:
      if (bandIndex % 4 == 0) await Future(() {});
  }
}

/// Streams `exportSvsRegionAsSvs`/`exportSvsRegionAsSvsToFile`'s pyramid
/// into [sink] (already open — this function neither opens nor closes
/// anything filesystem-specific, only [sink] itself, so it's usable from a
/// `MemoryByteSink` on every platform or a `dart:io`-backed sink natively).
/// See those public functions' doc comments for parameter semantics.
Future<void> streamSvsRegionAsSvs(
  SvsFile svsFile, {
  required RandomAccessByteSink sink,
  required int level,
  required int x,
  required int y,
  required int width,
  required int height,
  required int? tileSize,
  required int quality,
  required SvsExportCompression compression,
  required double jp2kCompressionRatio,
  required bool matchSourceCompression,
  required int? maxPixels,
  required SvsImageAdjustments adjustments,
  required bool includeLabelAndMacroImages,
  required bool includeSourceMetadata,
  required void Function(double progress)? onProgress,
  int? levelCount,
  SvsPyramidRebuildEffort effort = SvsPyramidRebuildEffort.balanced,
}) async {
  if (level < 0 || level >= svsFile.levels.length) {
    throw SvsFormatException(
      'Level $level out of range (have ${svsFile.levels.length} levels)',
    );
  }
  if (width <= 0 || height <= 0) {
    throw ArgumentError('width/height must be positive, got ${width}x$height');
  }
  if (levelCount != null && levelCount < 1) {
    throw ArgumentError.value(levelCount, 'levelCount', 'must be >= 1');
  }
  final pixelCount = width * height;
  if (maxPixels != null && pixelCount > maxPixels) {
    final estimatedMb = (pixelCount * 4 / (1024 * 1024)).round();
    throw ArgumentError(
      'Requested region is ${width}x$height ($pixelCount px), over the '
      '$maxPixels px safety limit (~$estimatedMb MB just for the raw pixel '
      'buffer). Crop a smaller rectangle, or pass a higher maxPixels if you '
      'really mean it.',
    );
  }

  // JPEG2000-compression exports encode via `encodeJ2k` below — no-op/
  // instant on native; on web this lazily instantiates the openjpeg_ffi
  // WASM module the first time it's actually needed.
  await initOpenJpegWasm();

  final sourceLevel = svsFile.levels[level];
  final effectiveTileSize = _resolveTileSize(
    tileSize,
    matchSourceCompression: matchSourceCompression,
    sourceLevel: sourceLevel,
  );
  if (effectiveTileSize <= 0) {
    throw ArgumentError.value(tileSize, 'tileSize', 'must be positive');
  }
  final sourceMppX = svsFile.metadata.mppX;
  final mpp = sourceMppX == null ? null : sourceMppX * sourceLevel.downsample;
  final appMag = svsFile.metadata.appMag;

  (compression, quality, jp2kCompressionRatio) = await _resolveExportEncoding(
    sourceLevel: sourceLevel,
    compression: compression,
    quality: quality,
    jp2kCompressionRatio: jp2kCompressionRatio,
    matchSourceCompression: matchSourceCompression,
  );

  final labelAndMacroImages = _sourceLabelAndMacroImages(
    svsFile,
    includeLabelAndMacroImages,
  );

  final tileCompression = compression == SvsExportCompression.jpeg2000
      ? ApCompression.jp2k
      : ApCompression.newJpeg;

  // `computePyramidLevelDims` already produces the maximal-smoothness 2x
  // cascade (halved down to one tile) — the "auto-increase levels" case
  // needs no extra logic beyond that default. `levelCount`, when given,
  // truncates that natural cascade early (fewer, coarser-capped levels —
  // the "decrease levels" case); when it's `>=` the natural count it's a
  // no-op, since generating anything finer than the natural cascade isn't
  // meaningful.
  final naturalLevelDims = computePyramidLevelDims(
    width,
    height,
    effectiveTileSize,
  );
  final levelDims = levelCount == null
      ? naturalLevelDims
      : naturalLevelDims.sublist(
          0,
          math.min(levelCount, naturalLevelDims.length),
        );
  final specs = [
    for (var i = 0; i < levelDims.length; i++)
      PyramidLevelSpec(
        width: levelDims[i].$1,
        height: levelDims[i].$2,
        tileWidth: effectiveTileSize,
        tileLength: effectiveTileSize,
        compression: tileCompression,
        imageDescription: i == 0
            ? _buildImageDescription(
                width: levelDims[0].$1,
                height: levelDims[0].$2,
                tileSize: effectiveTileSize,
                quality: quality,
                compression: compression,
                mpp: mpp,
                appMag: appMag,
                sourceFields: includeSourceMetadata
                    ? svsFile.metadata.raw
                    : const {},
              )
            : null,
      ),
  ];
  // The coarsest generated level doubles as the exported file's thumbnail —
  // an associated image `SvsImageView`'s minimap needs, same as a real
  // Aperio file carries, which a plain pyramid-levels-only export
  // previously never wrote at all. Normally that level is already
  // `<= effectiveTileSize` in both dimensions (by construction — see
  // `computePyramidLevelDims`), but a `levelCount` cap can truncate the
  // cascade before that point, so the thumbnail is still explicitly fit to
  // one tile here (matching `streamSvsRegionAsSvsPreservingLevels`, whose
  // coarsest level is never guaranteed to fit either).
  final (thumbWidth, thumbHeight) = _fitWithinSquare(
    levelDims.last.$1,
    levelDims.last.$2,
    effectiveTileSize,
  );
  final thumbSpec = AssociatedImageSpec(
    width: thumbWidth,
    height: thumbHeight,
    compression: ApCompression.newJpeg,
    photometricInterpretation: 6, // YCbCr — img.encodeJpg's normal output
    samplesPerPixel: 3,
    bitsPerSample: const [8, 8, 8],
    predictor: 1,
    rowsPerStrip: thumbHeight,
    stripCount: 1,
  );
  final extraSpecs = [
    for (final image in labelAndMacroImages) await _copySpec(image),
  ];
  final layout = planPyramidHeader(
    specs,
    associatedImages: [thumbSpec, ...extraSpecs],
  );

  try {
    await sink.writeFrom(layout.headerBytes);

    final tileSink = _TileSink(sink, specs.length);
    final builders = [
      for (var i = 0; i < specs.length; i++)
        _LevelBuilder(
          levelIndex: i,
          spec: specs[i],
          quality: quality,
          jp2kCompressionRatio: jp2kCompressionRatio,
          sink: tileSink,
        ),
    ];
    for (var i = 0; i < builders.length - 1; i++) {
      builders[i].next = builders[i + 1];
    }

    var rowsProcessed = 0;
    var srcY = 0;
    var bandIndex = 0;
    while (srcY < height) {
      final bandHeight = math.min(effectiveTileSize, height - srcY);
      final raw = await readSvsRegionRawRgba(
        svsFile,
        level: level,
        x: x,
        y: y + srcY,
        width: width,
        height: bandHeight,
      );
      adjustments.applyToRgba(raw);
      await builders[0].addRows([
        for (var r = 0; r < bandHeight; r++)
          Uint8List.sublistView(raw, r * width * 4, (r + 1) * width * 4),
      ]);

      rowsProcessed += bandHeight;
      srcY += bandHeight;
      onProgress?.call(rowsProcessed / height);
      await _yieldForEffort(effort, bandIndex);
      bandIndex++;
    }
    await builders[0].finish();
    // The coarsest level (last in `builders`, the one with no `next`)
    // accumulates its own raw bytes across every band it's emitted
    // (`_LevelBuilder._emitBand`) — unlike every finer level, it's never
    // guaranteed to fit in a single band once `levelCount` can truncate the
    // cascade before the natural "fits in one tile" point. `finalImage`
    // assembles the complete accumulated image lazily; resized down to fit
    // one tile (a no-op when it already does) to match `thumbSpec` above.
    var thumbnailImage = builders.last.finalImage!;
    if (thumbnailImage.width != thumbWidth ||
        thumbnailImage.height != thumbHeight) {
      thumbnailImage = img.copyResize(
        thumbnailImage,
        width: thumbWidth,
        height: thumbHeight,
        interpolation: img.Interpolation.average,
      );
    }

    await _writeSvsTail(
      sink: sink,
      layout: layout,
      tileSink: tileSink,
      levelCount: specs.length,
      thumbnailImage: thumbnailImage,
      quality: quality,
      labelAndMacroImages: labelAndMacroImages,
    );
  } finally {
    await sink.close();
  }
}

/// One output level's source: [width]x[height] pixels to crop from
/// [svsFile.levels][sourceIndex] at that level's own (`x`,`y`) — see
/// [_regionOnSourceLevel].
typedef _SourceLevelRegion = ({
  int sourceIndex,
  int x,
  int y,
  int width,
  int height,
});

/// [sourceLevel]'s own pixel-space rectangle covering the same physical area
/// as the level-0-space rectangle
/// (`level0X`,`level0Y`)-`level0Width`x`level0Height` — that rectangle
/// scaled down by [sourceLevel]'s own `downsample`, then clamped to
/// [sourceLevel]'s actual bounds (rounding, or the source's real dimensions
/// not perfectly matching its nominal downsample, could otherwise push it
/// out of range).
_SourceLevelRegion _regionOnSourceLevel(
  SvsLevel sourceLevel, {
  required double level0X,
  required double level0Y,
  required double level0Width,
  required double level0Height,
}) {
  final ds = sourceLevel.downsample;
  var rx = (level0X / ds).round();
  var ry = (level0Y / ds).round();
  var rw = (level0Width / ds).round();
  var rh = (level0Height / ds).round();

  rx = math.max(0, math.min(rx, sourceLevel.width - 1));
  ry = math.max(0, math.min(ry, sourceLevel.height - 1));
  rw = math.max(1, math.min(rw, sourceLevel.width - rx));
  rh = math.max(1, math.min(rh, sourceLevel.height - ry));

  return (sourceIndex: sourceLevel.index, x: rx, y: ry, width: rw, height: rh);
}

/// [width]x[height] scaled down (aspect-preserved) so neither dimension
/// exceeds [maxDim] — unchanged if it already doesn't. Used to size the
/// thumbnail derived from the coarsest region in
/// [streamSvsRegionAsSvsPreservingLevels], since (unlike
/// [streamSvsRegionAsSvs]'s halving-generated pyramid) that region isn't
/// guaranteed to already fit in one tile.
(int, int) _fitWithinSquare(int width, int height, int maxDim) {
  if (width <= maxDim && height <= maxDim) return (width, height);
  final scale = maxDim / math.max(width, height);
  return (
    math.max(1, (width * scale).round()),
    math.max(1, (height * scale).round()),
  );
}

/// Same as [streamSvsRegionAsSvs], but building
/// `exportSvsRegionAsSvsPreservingLevels`'s pyramid instead: one output
/// level per source level from [level] to the source's coarsest, each
/// cropped directly from that source level rather than downsampled from
/// [level]'s own decoded pixels.
Future<void> streamSvsRegionAsSvsPreservingLevels(
  SvsFile svsFile, {
  required RandomAccessByteSink sink,
  required int level,
  required int x,
  required int y,
  required int width,
  required int height,
  required int? tileSize,
  required int quality,
  required SvsExportCompression compression,
  required double jp2kCompressionRatio,
  required bool matchSourceCompression,
  required int? maxPixels,
  required SvsImageAdjustments adjustments,
  required bool includeLabelAndMacroImages,
  required bool includeSourceMetadata,
  required void Function(double progress)? onProgress,
  SvsPyramidRebuildEffort effort = SvsPyramidRebuildEffort.balanced,
}) async {
  if (level < 0 || level >= svsFile.levels.length) {
    throw SvsFormatException(
      'Level $level out of range (have ${svsFile.levels.length} levels)',
    );
  }
  if (width <= 0 || height <= 0) {
    throw ArgumentError('width/height must be positive, got ${width}x$height');
  }
  final pixelCount = width * height;
  if (maxPixels != null && pixelCount > maxPixels) {
    final estimatedMb = (pixelCount * 4 / (1024 * 1024)).round();
    throw ArgumentError(
      'Requested region is ${width}x$height ($pixelCount px), over the '
      '$maxPixels px safety limit (~$estimatedMb MB just for the raw pixel '
      'buffer). Crop a smaller rectangle, or pass a higher maxPixels if you '
      'really mean it.',
    );
  }

  // See the matching comment in streamSvsRegionAsSvs.
  await initOpenJpegWasm();

  final sourceLevel = svsFile.levels[level];
  final effectiveTileSize = _resolveTileSize(
    tileSize,
    matchSourceCompression: matchSourceCompression,
    sourceLevel: sourceLevel,
  );
  if (effectiveTileSize <= 0) {
    throw ArgumentError.value(tileSize, 'tileSize', 'must be positive');
  }
  final sourceMppX = svsFile.metadata.mppX;
  final mpp = sourceMppX == null ? null : sourceMppX * sourceLevel.downsample;
  final appMag = svsFile.metadata.appMag;

  (compression, quality, jp2kCompressionRatio) = await _resolveExportEncoding(
    sourceLevel: sourceLevel,
    compression: compression,
    quality: quality,
    jp2kCompressionRatio: jp2kCompressionRatio,
    matchSourceCompression: matchSourceCompression,
  );

  final labelAndMacroImages = _sourceLabelAndMacroImages(
    svsFile,
    includeLabelAndMacroImages,
  );

  final tileCompression = compression == SvsExportCompression.jpeg2000
      ? ApCompression.jp2k
      : ApCompression.newJpeg;

  // The requested rectangle, in level-0 pixel space — every other source
  // level's own matching rectangle is this same physical area scaled by
  // that level's `downsample`, so every generated output level covers
  // exactly the same region of the slide, just at that level's resolution.
  final level0X = x * sourceLevel.downsample;
  final level0Y = y * sourceLevel.downsample;
  final level0Width = width * sourceLevel.downsample;
  final level0Height = height * sourceLevel.downsample;

  final regions = <_SourceLevelRegion>[
    for (var j = level; j < svsFile.levels.length; j++)
      _regionOnSourceLevel(
        svsFile.levels[j],
        level0X: level0X,
        level0Y: level0Y,
        level0Width: level0Width,
        level0Height: level0Height,
      ),
  ];

  final specs = [
    for (var k = 0; k < regions.length; k++)
      PyramidLevelSpec(
        width: regions[k].width,
        height: regions[k].height,
        tileWidth: effectiveTileSize,
        tileLength: effectiveTileSize,
        compression: tileCompression,
        imageDescription: k == 0
            ? _buildImageDescription(
                width: regions[0].width,
                height: regions[0].height,
                tileSize: effectiveTileSize,
                quality: quality,
                compression: compression,
                mpp: mpp,
                appMag: appMag,
                sourceFields: includeSourceMetadata
                    ? svsFile.metadata.raw
                    : const {},
              )
            : null,
      ),
  ];

  final coarsestRegion = regions.last;
  final (thumbWidth, thumbHeight) = _fitWithinSquare(
    coarsestRegion.width,
    coarsestRegion.height,
    effectiveTileSize,
  );
  final thumbSpec = AssociatedImageSpec(
    width: thumbWidth,
    height: thumbHeight,
    compression: ApCompression.newJpeg,
    photometricInterpretation: 6, // YCbCr — img.encodeJpg's normal output
    samplesPerPixel: 3,
    bitsPerSample: const [8, 8, 8],
    predictor: 1,
    rowsPerStrip: thumbHeight,
    stripCount: 1,
  );
  final extraSpecs = [
    for (final image in labelAndMacroImages) await _copySpec(image),
  ];
  final layout = planPyramidHeader(
    specs,
    associatedImages: [thumbSpec, ...extraSpecs],
  );

  try {
    await sink.writeFrom(layout.headerBytes);

    final tileSink = _TileSink(sink, specs.length);
    final totalRows = regions.fold<int>(0, (sum, r) => sum + r.height);
    var rowsProcessedGlobal = 0;
    var bandIndex = 0;

    // Accumulates the coarsest level's own decoded bytes as they stream by,
    // so the thumbnail can be built from them afterwards without decoding
    // that (smallest, of every included level) region a second time.
    BytesBuilder? coarsestRawBuilder;

    for (var k = 0; k < regions.length; k++) {
      final region = regions[k];
      final isCoarsest = k == regions.length - 1;
      if (isCoarsest) coarsestRawBuilder = BytesBuilder(copy: false);

      final builder = _LevelBuilder(
        levelIndex: k,
        spec: specs[k],
        quality: quality,
        jp2kCompressionRatio: jp2kCompressionRatio,
        sink: tileSink,
      );

      var srcY = 0;
      while (srcY < region.height) {
        final bandHeight = math.min(effectiveTileSize, region.height - srcY);
        final raw = await readSvsRegionRawRgba(
          svsFile,
          level: region.sourceIndex,
          x: region.x,
          y: region.y + srcY,
          width: region.width,
          height: bandHeight,
        );
        adjustments.applyToRgba(raw);
        if (isCoarsest) coarsestRawBuilder!.add(raw);
        await builder.addRows([
          for (var r = 0; r < bandHeight; r++)
            Uint8List.sublistView(
              raw,
              r * region.width * 4,
              (r + 1) * region.width * 4,
            ),
        ]);

        rowsProcessedGlobal += bandHeight;
        srcY += bandHeight;
        onProgress?.call(rowsProcessedGlobal / totalRows);
        await _yieldForEffort(effort, bandIndex);
        bandIndex++;
      }
      await builder.finish();
    }

    var thumbnailImage = img.Image.fromBytes(
      width: coarsestRegion.width,
      height: coarsestRegion.height,
      bytes: coarsestRawBuilder!.takeBytes().buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    if (thumbnailImage.width != thumbWidth ||
        thumbnailImage.height != thumbHeight) {
      thumbnailImage = img.copyResize(
        thumbnailImage,
        width: thumbWidth,
        height: thumbHeight,
        interpolation: img.Interpolation.average,
      );
    }

    await _writeSvsTail(
      sink: sink,
      layout: layout,
      tileSink: tileSink,
      levelCount: specs.length,
      thumbnailImage: thumbnailImage,
      quality: quality,
      labelAndMacroImages: labelAndMacroImages,
    );
  } finally {
    await sink.close();
  }
}

/// `tileSize`'s resolved value: the caller's explicit choice if given, else
/// this function family's usual 256 default — or, under
/// [matchSourceCompression], [sourceLevel]'s own tile edge length instead.
int _resolveTileSize(
  int? tileSize, {
  required bool matchSourceCompression,
  required SvsLevel sourceLevel,
}) => tileSize ?? (matchSourceCompression ? sourceLevel.tileWidth : 256);

/// `compression`/`quality`/`jp2kCompressionRatio`'s resolved values: the
/// caller's explicit choices if [matchSourceCompression] is `false`, else
/// [sourceLevel]'s own compression scheme plus its own JPEG quality (parsed
/// from its `ImageDescription`) or an estimated JPEG2000 ratio (sampled from
/// its actual tile sizes) — falling back to the caller's choices when either
/// can't be determined. See [matchSourceCompression]'s own doc for why.
Future<(SvsExportCompression, int, double)> _resolveExportEncoding({
  required SvsLevel sourceLevel,
  required SvsExportCompression compression,
  required int quality,
  required double jp2kCompressionRatio,
  required bool matchSourceCompression,
}) async {
  if (!matchSourceCompression) {
    return (compression, quality, jp2kCompressionRatio);
  }
  if (sourceLevel.isJp2k) {
    final ratio = await _estimateSourceJp2kRatio(sourceLevel);
    return (
      SvsExportCompression.jpeg2000,
      quality,
      ratio ?? jp2kCompressionRatio,
    );
  }
  final sourceQuality = await _parseSourceJpegQuality(sourceLevel);
  return (
    SvsExportCompression.jpeg,
    sourceQuality ?? quality,
    jp2kCompressionRatio,
  );
}

/// The source file's own label/macro associated images — carried into an
/// export unmodified (see [_copySpec]) unless the caller opts out via
/// [include], since they describe the whole physical slide rather than any
/// particular crop of it.
List<SvsAssociatedImage> _sourceLabelAndMacroImages(
  SvsFile svsFile,
  bool include,
) {
  if (!include) return const <SvsAssociatedImage>[];
  return svsFile.associatedImages
      .where(
        (a) =>
            a.kind == AssociatedImageKind.label ||
            a.kind == AssociatedImageKind.macro,
      )
      .toList(growable: false);
}

/// Writes everything that comes after a pyramid export's tile data —
/// [thumbnailImage] (encoded fresh at [quality]), [labelAndMacroImages]'
/// strips (copied byte-for-byte from the source), then patches every
/// level's `TileOffsets`/`TileByteCounts` (from [tileSink]) and every
/// associated image's `StripOffsets`/`StripByteCounts` into the
/// placeholders [layout] reserved for them. Shared by every pyramid-export
/// entry point in this file — the bookkeeping is identical regardless of how
/// the pyramid's own tiles were produced.
Future<void> _writeSvsTail({
  required RandomAccessByteSink sink,
  required PyramidHeaderLayout layout,
  required _TileSink tileSink,
  required int levelCount,
  required img.Image thumbnailImage,
  required int quality,
  required List<SvsAssociatedImage> labelAndMacroImages,
}) async {
  var writePos = await sink.position();

  final thumbBytes = img.encodeJpg(thumbnailImage, quality: quality);
  final thumbOffset = writePos;
  await sink.setPosition(writePos);
  await sink.writeFrom(thumbBytes);
  writePos += thumbBytes.length;
  if (writePos.isOdd) {
    await sink.writeFrom(Uint8List(1));
    writePos += 1;
  }

  // Each label/macro image's strips are copied byte-for-byte (no decode, no
  // re-encode) straight from the source file.
  final extraStripData = <(List<int>, List<int>)>[];
  for (final source in labelAndMacroImages) {
    final stripCount = await source.stripCount;
    final offsets = <int>[];
    final byteCounts = <int>[];
    for (var i = 0; i < stripCount; i++) {
      final bytes = await source.readRawStripBytes(i);
      if (bytes.isEmpty) {
        offsets.add(0);
        byteCounts.add(0);
        continue;
      }
      offsets.add(writePos);
      byteCounts.add(bytes.length);
      await sink.setPosition(writePos);
      await sink.writeFrom(bytes);
      writePos += bytes.length;
      if (writePos.isOdd) {
        await sink.writeFrom(Uint8List(1));
        writePos += 1;
      }
    }
    extraStripData.add((offsets, byteCounts));
  }

  for (var i = 0; i < levelCount; i++) {
    final patch = layout.levels[i];
    await sink.setPosition(patch.tileOffsetsValuePos);
    await sink.writeFrom(
      encodeTiffInts(tileSink.offsetsPerLevel[i], TiffType.long8),
    );
    await sink.setPosition(patch.tileByteCountsValuePos);
    await sink.writeFrom(
      encodeTiffInts(tileSink.byteCountsPerLevel[i], TiffType.long),
    );
  }

  final thumbPatch = layout.associatedImages[0];
  await sink.setPosition(thumbPatch.stripOffsetsValuePos);
  await sink.writeFrom(encodeTiffInts([thumbOffset], TiffType.long8));
  await sink.setPosition(thumbPatch.stripByteCountsValuePos);
  await sink.writeFrom(encodeTiffInts([thumbBytes.length], TiffType.long));

  for (var i = 0; i < labelAndMacroImages.length; i++) {
    final patch = layout.associatedImages[1 + i];
    final (offsets, byteCounts) = extraStripData[i];
    await sink.setPosition(patch.stripOffsetsValuePos);
    await sink.writeFrom(encodeTiffInts(offsets, TiffType.long8));
    await sink.setPosition(patch.stripByteCountsValuePos);
    await sink.writeFrom(encodeTiffInts(byteCounts, TiffType.long));
  }
}

/// The JPEG quality [sourceLevel] was itself encoded at, parsed straight out
/// of its own `ImageDescription` (e.g. `...(256x256) JPEG/RGB Q=70...`) —
/// or `null` if that level has no `ImageDescription`, or it has no `Q=NN`
/// in it. Used by [matchSourceCompression] instead of guessing.
final _jpegQualityPattern = RegExp(r'Q\s*=\s*(\d+)');

Future<int?> _parseSourceJpegQuality(SvsLevel sourceLevel) async {
  final description = await sourceLevel.imageDescription;
  if (description == null) return null;
  final match = _jpegQualityPattern.firstMatch(description);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// An effective JPEG2000 `compressionRatio` (see `encodeJ2k`) that
/// approximates how hard [sourceLevel] was itself actually compressed —
/// unlike JPEG quality, Aperio never records this in `ImageDescription`, so
/// it's estimated by sampling a handful of the level's real on-disk tile
/// byte counts and comparing them against that tile's uncompressed
/// (width x height x 3-channel RGB) size. Returns `null` if every sampled
/// tile turns out to be sparse (byte count 0), leaving nothing to measure.
Future<double?> _estimateSourceJp2kRatio(SvsLevel sourceLevel) async {
  final tilesX = sourceLevel.tilesAcrossX;
  final tilesY = sourceLevel.tilesAcrossY;
  final totalTiles = tilesX * tilesY;
  if (totalTiles == 0) return null;

  const maxSamples = 8;
  final sampleCount = math.min(maxSamples, totalTiles);
  var sampledBytes = 0;
  var sampledTiles = 0;
  for (var i = 0; i < sampleCount; i++) {
    final tileIndex = (i * totalTiles) ~/ sampleCount;
    final tx = tileIndex % tilesX;
    final ty = tileIndex ~/ tilesX;
    final byteCount = await sourceLevel.tileByteCount(tx, ty);
    if (byteCount <= 0) continue;
    sampledBytes += byteCount;
    sampledTiles++;
  }
  if (sampledTiles == 0) return null;

  final uncompressedTileBytes =
      sourceLevel.tileWidth * sourceLevel.tileLength * 3;
  final avgBytes = sampledBytes / sampledTiles;
  // Clamped to encodeJ2k's practically useful range — an unclamped ratio
  // from a near-empty or degenerate tile could otherwise come out absurdly
  // high (or below 1, i.e. "expand").
  return (uncompressedTileBytes / avgBytes).clamp(1.0, 500.0);
}

/// Builds an [AssociatedImageSpec] that lets [image]'s strips be copied
/// byte-for-byte into the exported file — same compression/photometric/
/// sample layout/JPEGTables/description as the source, so the copy decodes
/// identically once reopened.
Future<AssociatedImageSpec> _copySpec(SvsAssociatedImage image) async {
  return AssociatedImageSpec(
    width: image.width,
    height: image.height,
    compression: image.compression,
    photometricInterpretation: image.photometricInterpretation,
    samplesPerPixel: image.samplesPerPixel,
    bitsPerSample: image.bitsPerSample,
    predictor: image.predictor,
    rowsPerStrip: await image.rowsPerStrip,
    stripCount: await image.stripCount,
    jpegTables: image.isJpeg ? await image.jpegTables : null,
    imageDescription: await image.imageDescription,
  );
}

/// Sequentially appends tile JPEG bytes to the output sink (starting right
/// after the header `planPyramidHeader` already wrote), recording each
/// tile's final offset/byte-count for the header patch pass. Tiles for a
/// level must be written in row-major (`ty * tilesAcrossX + tx`) order —
/// `_LevelBuilder` always emits full tile-row bands in that order, so this
/// never needs to reorder anything.
class _TileSink {
  final RandomAccessByteSink sink;
  final List<List<int>> offsetsPerLevel;
  final List<List<int>> byteCountsPerLevel;
  int _pos = -1;

  _TileSink(this.sink, int levelCount)
    : offsetsPerLevel = List.generate(levelCount, (_) => <int>[]),
      byteCountsPerLevel = List.generate(levelCount, (_) => <int>[]);

  Future<void> writeTile(int levelIndex, Uint8List bytes) async {
    _pos = _pos < 0 ? await sink.position() : _pos;
    offsetsPerLevel[levelIndex].add(_pos);
    byteCountsPerLevel[levelIndex].add(bytes.length);
    await sink.writeFrom(bytes);
    _pos += bytes.length;
    if (_pos.isOdd) {
      await sink.writeFrom(Uint8List(1));
      _pos += 1;
    }
  }
}

/// Builds one pyramid level by accumulating raw RGBA rows pushed in via
/// [addRows], flushing a JPEG-encoded, sink-written tile-row band as soon as
/// [PyramidLevelSpec.tileLength] rows have accumulated (or, in [finish], the
/// final shorter band once the source is exhausted). Each flushed band is
/// also box-filter-downsampled 2x and pushed into [next] — the next-coarser
/// level's own accumulator — cascading the whole pyramid from a single
/// stream of level-0 source bands, never holding more than a couple of
/// tile-row bands per level in memory at once.
class _LevelBuilder {
  final int levelIndex;
  final PyramidLevelSpec spec;
  final int quality;
  final double jp2kCompressionRatio;
  final _TileSink sink;
  _LevelBuilder? next;

  /// Every band's raw bytes accumulated so far, for the coarsest level only
  /// (the one with no [next] to cascade into instead) — a `levelCount` cap
  /// can truncate the pyramid before the natural "fits in one tile" point,
  /// so [_emitBand] may run more than once for that level, unlike before
  /// this field existed. `null` until the first band is emitted.
  BytesBuilder? _coarsestRawBytes;
  int _coarsestHeight = 0;

  /// The complete coarsest-level image, assembled from every band
  /// accumulated into [_coarsestRawBytes] — `null` for any builder with a
  /// [next] (only the coarsest level tracks this), or before [finish] has
  /// run. The exported file's thumbnail is derived from this rather than
  /// decoding/downsampling the source a second time.
  img.Image? get finalImage {
    final raw = _coarsestRawBytes;
    if (raw == null) return null;
    return img.Image.fromBytes(
      width: spec.width,
      height: _coarsestHeight,
      bytes: raw.toBytes().buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  }

  final List<Uint8List> _pendingRows = [];

  _LevelBuilder({
    required this.levelIndex,
    required this.spec,
    required this.quality,
    required this.jp2kCompressionRatio,
    required this.sink,
  });

  Future<void> addRows(List<Uint8List> rows) async {
    _pendingRows.addAll(rows);
    await _flushFullBands();
  }

  Future<void> finish() async {
    await _flushFullBands();
    if (_pendingRows.isNotEmpty) {
      final band = List<Uint8List>.of(_pendingRows);
      _pendingRows.clear();
      await _emitBand(band);
    }
    await next?.finish();
  }

  Future<void> _flushFullBands() async {
    while (_pendingRows.length >= spec.tileLength) {
      final band = _pendingRows.sublist(0, spec.tileLength);
      _pendingRows.removeRange(0, spec.tileLength);
      await _emitBand(band);
    }
  }

  Future<void> _emitBand(List<Uint8List> bandRows) async {
    final bandHeight = bandRows.length;
    final bandBytes = Uint8List(spec.width * bandHeight * 4);
    for (var r = 0; r < bandHeight; r++) {
      bandBytes.setRange(
        r * spec.width * 4,
        (r + 1) * spec.width * 4,
        bandRows[r],
      );
    }

    final bandImage = img.Image.fromBytes(
      width: spec.width,
      height: bandHeight,
      bytes: bandBytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    if (next == null) {
      _coarsestRawBytes ??= BytesBuilder(copy: false);
      _coarsestRawBytes!.add(bandBytes);
      _coarsestHeight += bandHeight;
    }
    for (var tx = 0; tx < spec.tilesAcrossX; tx++) {
      final tileLeft = tx * spec.tileWidth;
      final tileW = math.min(spec.tileWidth, spec.width - tileLeft);
      final tile = img.copyCrop(
        bandImage,
        x: tileLeft,
        y: 0,
        width: tileW,
        height: bandHeight,
      );
      final Uint8List tileBytes;
      if (spec.compression == ApCompression.jp2k) {
        // Unlike this builder's JPEG tiles — whose readers (`region_decoder
        // .dart`, `lod_controller.dart`) already handle a boundary tile
        // decoding smaller than nominal — every JP2K reader in this package
        // assumes a tile decodes at exactly the nominal tile-grid size
        // (true of real Aperio JP2K files, which always pad). So a boundary
        // tile here is padded up to that same full nominal size before
        // encoding, rather than encoded at its true (smaller) size like the
        // JPEG path above.
        final padded = tileW == spec.tileWidth && bandHeight == spec.tileLength
            ? tile
            : img.copyExpandCanvas(
                tile,
                newWidth: spec.tileWidth,
                newHeight: spec.tileLength,
                position: img.ExpandCanvasPosition.topLeft,
                backgroundColor: img.ColorRgb8(0, 0, 0),
              );
        tileBytes = encodeJ2k(
          padded.getBytes(order: img.ChannelOrder.rgb),
          width: spec.tileWidth,
          height: spec.tileLength,
          numComponents: 3,
          compressionRatio: jp2kCompressionRatio,
        );
      } else {
        tileBytes = img.encodeJpg(tile, quality: quality);
      }
      await sink.writeTile(levelIndex, tileBytes);
    }

    if (next != null) {
      await next!.addRows(_boxDownsample2x(bandBytes, spec.width, bandHeight));
    }
  }
}

/// Box-filters [src] (tightly-packed RGBA, [width]x[height]) down by 2x in
/// both dimensions, returning the result as a list of rows (row-major, each
/// `ceil(width / 2) * 4` bytes) rather than a flat buffer — matches
/// [_LevelBuilder.addRows]'s input shape directly. A trailing odd row/column
/// is averaged from just its single remaining source pixel(s), the same
/// "round up" rule [computePyramidLevelDims] uses to size the next level.
List<Uint8List> _boxDownsample2x(Uint8List src, int width, int height) {
  final outWidth = (width / 2).ceil();
  final outHeight = (height / 2).ceil();
  final rows = <Uint8List>[];
  for (var oy = 0; oy < outHeight; oy++) {
    final y0 = oy * 2;
    final hasY1 = y0 + 1 < height;
    final row = Uint8List(outWidth * 4);
    for (var ox = 0; ox < outWidth; ox++) {
      final x0 = ox * 2;
      final hasX1 = x0 + 1 < width;
      var r = 0, g = 0, b = 0, a = 0, count = 0;
      void accum(int xx, int yy) {
        final idx = (yy * width + xx) * 4;
        r += src[idx];
        g += src[idx + 1];
        b += src[idx + 2];
        a += src[idx + 3];
        count++;
      }

      accum(x0, y0);
      if (hasX1) accum(x0 + 1, y0);
      if (hasY1) accum(x0, y0 + 1);
      if (hasX1 && hasY1) accum(x0 + 1, y0 + 1);

      row[ox * 4] = (r / count).round();
      row[ox * 4 + 1] = (g / count).round();
      row[ox * 4 + 2] = (b / count).round();
      row[ox * 4 + 3] = (a / count).round();
    }
    rows.add(row);
  }
  return rows;
}

/// Fields from the source file's own `ImageDescription` that describe its
/// absolute position/size within the *original* slide — meaningless (and
/// actively misleading) once carried into a crop, so [_buildImageDescription]
/// drops them rather than copying them through with `sourceFields`.
const _positionalMetadataFields = {
  'Left',
  'Top',
  'OriginalWidth',
  'OriginalHeight',
};

/// An Aperio-style `ImageDescription` for the cropped file's level 0 —
/// enough for [SvsMetadata.parse] (via [SvsFile.open]) to recover [mpp] and
/// [appMag] when the exported file is reopened.
String _buildImageDescription({
  required int width,
  required int height,
  required int tileSize,
  required int quality,
  required SvsExportCompression compression,
  required double? mpp,
  required int? appMag,
  required Map<String, String> sourceFields,
}) {
  // Purely informational — `SvsMetadata.parse` only reads the `|`-separated
  // fields below, never this header line — so it's fine that "Q=" has no
  // real JPEG2000 equivalent.
  final encodingLabel = compression == SvsExportCompression.jpeg2000
      ? 'JP2000/RGB'
      : 'JPEG/RGB Q=$quality';
  final header =
      'Aperio Image Library v1.0\r\n'
      '${width}x$height [0,0 ${width}x$height] ($tileSize x $tileSize) '
      '$encodingLabel';
  final fields = <String>[
    if (appMag != null) 'AppMag = $appMag',
    if (mpp != null) 'MPP = ${mpp.toStringAsFixed(4)}',
    for (final entry in sourceFields.entries)
      // AppMag/MPP are recomputed above (MPP scales with the source level's
      // downsample, so the raw source value would be wrong here); every
      // other field the source file carried — Filename, Date, Time, User,
      // ScanScope ID, StripeWidth, DisplayColor, etc. — is preserved as-is.
      if (entry.key != 'AppMag' &&
          entry.key != 'MPP' &&
          !_positionalMetadataFields.contains(entry.key))
        '${entry.key} = ${entry.value}',
  ];
  return fields.isEmpty ? header : '$header|${fields.join('|')}';
}
