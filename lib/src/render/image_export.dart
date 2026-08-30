import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../errors.dart';
import '../svs/svs_file.dart';
import 'associated_image_decoder.dart';
import 'image_adjustments.dart';
import 'region_decoder.dart';

/// Raster formats [encodeSvsImage] (and the `exportSvs*` convenience
/// wrappers below) can encode a decoded image to.
enum SvsImageFormat {
  /// Lossless, supports transparency. The safe default for anything that
  /// might have transparent padding (e.g. a region that hangs off the
  /// slide's edge).
  png,

  /// Lossy, no alpha channel — [encodeSvsImage]'s `quality` parameter only
  /// applies here. Smallest files, best for photographic tissue regions
  /// where some compression artifacting is acceptable.
  jpeg,

  /// Uncompressed, no alpha channel. Large files; mainly useful for
  /// interop with tools that don't read PNG/TIFF.
  bmp,

  /// Lossless, supports transparency. Larger files than PNG but widely
  /// accepted by desktop image-editing and pathology tooling.
  tiff,

  /// Lossless, supports transparency, smaller than PNG for most photo-like
  /// content — but less universally supported by older tooling.
  webp,
}

/// Encodes an already-decoded [image] — typically the result of
/// [readSvsRegion] or [decodeAssociatedImage] — to [format]'s bytes.
///
/// [quality] (1-100, default 92) only applies to [SvsImageFormat.jpeg];
/// every other format is lossless and ignores it. JPEG has no alpha channel,
/// so any transparent padding (e.g. from a region that hung off the slide's
/// edge) is flattened to opaque black — use [SvsImageFormat.png] or
/// [SvsImageFormat.tiff] instead if that transparency needs to survive.
///
/// [adjustments] (default [SvsImageAdjustments.none]) is applied to the
/// decoded pixels before encoding — the same brightness/contrast/shadow/
/// highlight adjustment [SvsImageView.adjustments] applies live.
///
/// Does not dispose [image] — the caller still owns it.
Future<Uint8List> encodeSvsImage(
  ui.Image image, {
  required SvsImageFormat format,
  int quality = 92,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
}) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) {
    throw StateError(
      'Image.toByteData returned null (the image may already be disposed)',
    );
  }
  final pixels = data.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  adjustments.applyToRgba(pixels);
  final decoded = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: pixels.buffer,
    bytesOffset: pixels.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );

  switch (format) {
    case SvsImageFormat.png:
      return img.encodePng(decoded);
    case SvsImageFormat.jpeg:
      if (quality < 1 || quality > 100) {
        throw ArgumentError.value(
          quality,
          'quality',
          'must be between 1 and 100',
        );
      }
      return img.encodeJpg(decoded, quality: quality);
    case SvsImageFormat.bmp:
      return img.encodeBmp(decoded);
    case SvsImageFormat.tiff:
      return img.encodeTiff(decoded);
    case SvsImageFormat.webp:
      return img.encodeWebP(decoded);
  }
}

/// Crops [level]'s (`x`,`y`)-`width`x`height` rectangle — see [readSvsRegion]
/// for coordinate semantics — and encodes it straight to [format]'s bytes: a
/// one-call [readSvsRegion] + [encodeSvsImage] that disposes the
/// intermediate decoded image for you.
///
/// This produces a single flat raster, so it inherently needs a
/// `width * height * 4`-byte buffer at some point — unlike
/// [exportSvsRegionAsSvsToFile] (a *tiled* pyramidal `.svs` file), that
/// floor can't be streamed away. For a crop large enough that this matters,
/// prefer that function instead, if a tiled slide file is an acceptable
/// output shape. [onProgress] (0.0-1.0), if given, is invoked as each source
/// tile is composited into the result.
///
/// Must run on the main isolate, like [readSvsRegion].
Future<Uint8List> exportSvsRegion(
  SvsFile svsFile, {
  required int level,
  required int x,
  required int y,
  required int width,
  required int height,
  required SvsImageFormat format,
  int quality = 92,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
  void Function(double progress)? onProgress,
}) async {
  final image = await readSvsRegion(
    svsFile,
    level: level,
    x: x,
    y: y,
    width: width,
    height: height,
    onProgress: onProgress,
  );
  try {
    return await encodeSvsImage(
      image,
      format: format,
      quality: quality,
      adjustments: adjustments,
    );
  } finally {
    image.dispose();
  }
}

/// Decodes an associated [image] (thumbnail/label/macro) and encodes it
/// straight to [format]'s bytes: a one-call [decodeAssociatedImage] +
/// [encodeSvsImage] that disposes the intermediate decoded image for you.
///
/// Must run on the main isolate, like [decodeAssociatedImage].
Future<Uint8List> exportAssociatedImage(
  SvsAssociatedImage image, {
  required SvsImageFormat format,
  int quality = 92,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
}) async {
  final decoded = await decodeAssociatedImage(image);
  try {
    return await encodeSvsImage(
      decoded,
      format: format,
      quality: quality,
      adjustments: adjustments,
    );
  } finally {
    decoded.dispose();
  }
}

/// Convenience value for [exportSvsLevel]'s `maxPixels`, for a caller that
/// wants to opt back into the old fail-fast behavior: 8000x8000, roughly a
/// 256MB raw RGBA buffer.
const defaultExportMaxPixels = 64000000;

/// Encodes an entire pyramid [level] to [format]'s bytes.
///
/// Level 0 of a real slide is routinely 50,000-150,000px per side —
/// decoding and encoding that whole level allocates 4 bytes/pixel *twice*
/// (once compositing the tiles, once again inside the format encoder)
/// before a single output byte exists, easily gigabytes of RAM and a
/// multi-minute encode. There's no size limit by default; pass [maxPixels]
/// (e.g. [defaultExportMaxPixels]) to throw [ArgumentError] up front instead
/// of attempting an export over a size you've budgeted for. Prefer
/// [exportSvsRegion] for a specific rectangle, or a coarser (higher-index,
/// smaller) level, when you don't actually need the full-resolution export
/// — or [exportSvsRegionAsSvsToFile] for a very large export, which streams
/// instead of needing the whole level in memory.
///
/// Must run on the main isolate, like [readSvsRegion].
Future<Uint8List> exportSvsLevel(
  SvsFile svsFile, {
  required int level,
  required SvsImageFormat format,
  int quality = 92,
  int? maxPixels,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
  void Function(double progress)? onProgress,
}) async {
  if (level < 0 || level >= svsFile.levels.length) {
    throw SvsFormatException(
      'Level $level out of range (have ${svsFile.levels.length} levels)',
    );
  }
  final lvl = svsFile.levels[level];
  final pixelCount = lvl.width * lvl.height;
  if (maxPixels != null && pixelCount > maxPixels) {
    final estimatedMb = (pixelCount * 4 / (1024 * 1024)).round();
    throw ArgumentError(
      'Level $level is ${lvl.width}x${lvl.height} ($pixelCount px), over '
      'the $maxPixels px safety limit (~$estimatedMb MB just for the raw '
      'pixel buffer). Pass a smaller/coarser level (higher SvsLevel.index), '
      'crop a rectangle with exportSvsRegion instead, or raise maxPixels if '
      'you really mean it.',
    );
  }
  return exportSvsRegion(
    svsFile,
    level: level,
    x: 0,
    y: 0,
    width: lvl.width,
    height: lvl.height,
    format: format,
    quality: quality,
    adjustments: adjustments,
    onProgress: onProgress,
  );
}
