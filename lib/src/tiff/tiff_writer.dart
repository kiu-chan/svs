// A purpose-built (not generic) tiled-BigTIFF *header* writer: lays out
// exactly the tag set `svs_file.dart`'s reader already understands for a
// pyramid level (ImageWidth/ImageLength/BitsPerSample/Compression/
// PhotometricInterpretation/[ImageDescription]/SamplesPerPixel/TileWidth/
// TileLength/TileOffsets/TileByteCounts), with every tile already encoded as
// a standalone JPEG (no shared JPEGTables — `spliceJpegTile` already treats
// tiles without one as self-contained).
//
// Unlike a typical TIFF writer, this doesn't take tile bytes up front: tile
// data for a large crop is produced by a streaming cascade (see
// `render/svs_pyramid_export.dart`) that can't afford to hold every level's
// worth of encoded tiles in memory at once. So the header/IFD layout —
// which only depends on level *dimensions*, not tile *contents* — is
// planned first (`planPyramidHeader`), and the caller streams tile bytes to
// the file after it, then comes back to patch in the real TileOffsets/
// TileByteCounts values once they're known (`PyramidLevelPatch`). Internal
// to this package: the public entry point is `render/svs_pyramid_export.dart`.
import 'dart:convert';
import 'dart:typed_data';

import 'tiff_types.dart';

/// One pyramid level's dimensions/tiling, enough to plan its IFD layout —
/// no tile pixel data needed. [imageDescription] is only meaningful (and
/// only actually written) for level 0 — `SvsFile` only ever parses the
/// first level's `ImageDescription` (see `SvsFile._fromTiff`).
class PyramidLevelSpec {
  final int width;
  final int height;
  final int tileWidth;
  final int tileLength;
  final String? imageDescription;

  const PyramidLevelSpec({
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileLength,
    this.imageDescription,
  });

  int get tilesAcrossX => tilesAcross(width, tileWidth);
  int get tilesAcrossY => tilesAcross(height, tileLength);
  int get tileCount => tilesAcrossX * tilesAcrossY;
}

/// Where, once a level's real tile offsets/byte-counts are known, to seek
/// back and write them — [tileOffsetsValuePos]/[tileByteCountsValuePos] are
/// absolute file positions, valid whether that tag's value ended up inline
/// in its IFD entry or in an out-of-line blob (both are just "a position to
/// write bytes at").
class PyramidLevelPatch {
  final int tileOffsetsValuePos;
  final int tileByteCountsValuePos;
  final int tileCount;

  const PyramidLevelPatch({
    required this.tileOffsetsValuePos,
    required this.tileByteCountsValuePos,
    required this.tileCount,
  });
}

/// A non-tiled, strip-based associated image IFD (thumbnail/label/macro),
/// chained after the last pyramid level's IFD — the same shape a real Aperio
/// file's own associated images take, which `SvsFile` already knows how to
/// read back (`../svs/svs_file.dart`). Generic enough to cover two very
/// different uses: a freshly-encoded single-strip JPEG thumbnail (built from
/// the coarsest generated pyramid level), and a byte-for-byte copy of a
/// source file's own label/macro image — same [compression]/
/// [photometricInterpretation]/[samplesPerPixel]/[bitsPerSample]/
/// [predictor]/[rowsPerStrip]/[stripCount]/[jpegTables]/[imageDescription]
/// as the original, so its strips can be copied over unmodified (no decode,
/// no re-encode) and still read back identically.
///
/// [photometricInterpretation] is `-1` when the source image had none (some
/// associated images legitimately omit it) — that sentinel, same as
/// `SvsAssociatedImage.photometricInterpretation`'s, means "don't write tag
/// 262 at all", not "write -1".
class AssociatedImageSpec {
  final int width;
  final int height;
  final int compression;
  final int photometricInterpretation;
  final int samplesPerPixel;
  final List<int> bitsPerSample;
  final int predictor;
  final int rowsPerStrip;
  final int stripCount;
  final Uint8List? jpegTables;
  final String? imageDescription;

  const AssociatedImageSpec({
    required this.width,
    required this.height,
    required this.compression,
    required this.photometricInterpretation,
    required this.samplesPerPixel,
    required this.bitsPerSample,
    required this.predictor,
    required this.rowsPerStrip,
    required this.stripCount,
    this.jpegTables,
    this.imageDescription,
  });
}

/// Where, once an associated image's real strip offsets/byte-counts are
/// known, to seek back and write them — mirrors [PyramidLevelPatch] for a
/// non-tiled, (possibly multi-strip) associated-image IFD.
class AssociatedImagePatch {
  final int stripOffsetsValuePos;
  final int stripByteCountsValuePos;
  final int stripCount;

  const AssociatedImagePatch({
    required this.stripOffsetsValuePos,
    required this.stripByteCountsValuePos,
    required this.stripCount,
  });
}

/// Result of [planPyramidHeader]: the header bytes (header + every level's
/// IFD, chained via next-IFD offsets, with TileOffsets/TileByteCounts left
/// zero-filled) plus each level's patch positions, in the same order as the
/// input `levels` — plus, for each `associatedImages` spec given (same
/// order), that IFD's own patch positions.
class PyramidHeaderLayout {
  final Uint8List headerBytes;
  final List<PyramidLevelPatch> levels;
  final List<AssociatedImagePatch> associatedImages;

  const PyramidHeaderLayout(
    this.headerBytes,
    this.levels, {
    this.associatedImages = const [],
  });

  /// File position immediately after the header — where tile data streaming
  /// should begin.
  int get tileDataStart => headerBytes.length;
}

/// One IFD tag entry pending layout: [count]/[type] are always known up
/// front (needed to compute byte layout before any value is final), but
/// [encodedValue] is null for `TileOffsets` (324) and `TileByteCounts`
/// (325) — their real values are only known once tile streaming finishes,
/// so their space is reserved (zero-filled) here and patched later.
class _PendingTag {
  final int id;
  final int type;
  final int count;
  final Uint8List? encodedValue;

  const _PendingTag(this.id, this.type, this.count, this.encodedValue);

  int get totalBytes => count * tiffTypeSize(type);
}

class _LevelHeaderPlan {
  final List<_PendingTag> tags;
  final List<int?> blobOffsets; // per tag: null = inline, else out-of-line

  const _LevelHeaderPlan({required this.tags, required this.blobOffsets});
}

/// Encodes [values] as [type]'s on-disk byte representation — `SHORT`,
/// `LONG`, or `LONG8` only (the only integer tag types this writer needs).
Uint8List encodeTiffInts(
  List<int> values,
  int type, [
  Endian order = Endian.little,
]) {
  final size = tiffTypeSize(type);
  final bytes = Uint8List(size * values.length);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < values.length; i++) {
    final o = i * size;
    switch (type) {
      case TiffType.short:
        data.setUint16(o, values[i], order);
      case TiffType.long:
        data.setUint32(o, values[i], order);
      case TiffType.long8:
        data.setUint64(o, values[i], order);
      default:
        throw UnsupportedError('encodeTiffInts does not support type $type');
    }
  }
  return bytes;
}

/// Pure geometry: the width/height of every pyramid level generated from a
/// [width]x[height] source, each next level roughly half the previous, down
/// to one that fits in a single [tileSize]x[tileSize] tile.
///
/// Height uses a *chunked* halving (as if the source arrived in bands of
/// exactly [tileSize] rows, with the halving rounded per band rather than
/// once over the whole level) rather than a single `ceil(height / 2)` —
/// because that's exactly what the streaming pyramid builder actually does
/// (see `svs_pyramid_export.dart`'s `_LevelBuilder`, which only ever
/// downsamples fully-accumulated [tileSize]-row bands, plus one shorter
/// final band). The two formulas agree whenever [tileSize] is even (the
/// common case — default 256), but only the chunked one is correct in
/// general, so the streamed cascade's actual output height always matches
/// what's declared in the file header. Width isn't chunked (each band spans
/// the level's full width), so it keeps the simple `ceil(width / 2)`.
List<(int, int)> computePyramidLevelDims(int width, int height, int tileSize) {
  final dims = <(int, int)>[];
  var w = width;
  var h = height;
  while (true) {
    dims.add((w, h));
    if (w <= tileSize && h <= tileSize) break;
    final nextW = w <= 1 ? 1 : (w / 2).ceil();
    final nextH = h <= 1 ? 1 : _chunkedHalve(h, tileSize);
    w = nextW;
    h = nextH;
  }
  return dims;
}

int _chunkedHalve(int length, int chunk) {
  if (length <= chunk) return (length / 2).ceil();
  final fullChunks = length ~/ chunk;
  final remainder = length % chunk;
  final halfChunk = (chunk / 2).ceil();
  return fullChunks * halfChunk + (remainder > 0 ? (remainder / 2).ceil() : 0);
}

/// Plans the header/IFD region of a tiled pyramid BigTIFF for [levels]
/// (level 0 = full resolution, each next one progressively downsampled —
/// order matters, it's the order IFDs are chained in), without needing any
/// tile pixel data yet. Always BigTIFF (64-bit offsets) — simpler than
/// picking classic vs. Big per file, and this package's own reader
/// (`TiffFile`) already handles both, so there's no compatibility reason to
/// prefer classic TIFF here.
///
/// The caller is expected to: write [PyramidHeaderLayout.headerBytes] at the
/// start of the output file, then stream each level's tile JPEG bytes
/// starting at [PyramidHeaderLayout.tileDataStart] (sequential appends, tile
/// order matching `tilesAcrossX`/`tilesAcrossY`'s row-major order), then each
/// [associatedImages] spec's strips (in order, [AssociatedImageSpec.stripCount]
/// per image), and finally seek back to each [PyramidLevelPatch]'s (and
/// [PyramidHeaderLayout.associatedImages]'s) positions and write the real
/// offsets/byte-counts (via [encodeTiffInts] with [TiffType.long8]/
/// [TiffType.long] respectively).
PyramidHeaderLayout planPyramidHeader(
  List<PyramidLevelSpec> levels, {
  List<AssociatedImageSpec> associatedImages = const [],
}) {
  const order = Endian.little;
  const headerSize = 16;
  const dirCountFieldSize = 8;
  const entrySize = 20; // id(2) + type(2) + count(8) + value/offset(8)
  const valueFieldSize = 8;

  final ifdOffsets = <int>[];
  final ifdPlans = <_LevelHeaderPlan>[];
  var pos = headerSize;

  void planIfd(List<_PendingTag> tags) {
    ifdOffsets.add(pos);
    pos += dirCountFieldSize + tags.length * entrySize + valueFieldSize;

    final blobOffsets = <int?>[];
    for (final t in tags) {
      if (t.totalBytes <= valueFieldSize) {
        blobOffsets.add(null);
      } else {
        blobOffsets.add(pos);
        pos += t.totalBytes;
        if (pos.isOdd) pos += 1;
      }
    }

    ifdPlans.add(_LevelHeaderPlan(tags: tags, blobOffsets: blobOffsets));
  }

  for (final level in levels) {
    final tileCount = level.tileCount;
    final descBytes = level.imageDescription == null
        ? null
        : Uint8List.fromList([...utf8.encode(level.imageDescription!), 0]);

    planIfd([
      _PendingTag(
        256,
        TiffType.long,
        1,
        encodeTiffInts([level.width], TiffType.long, order),
      ),
      _PendingTag(
        257,
        TiffType.long,
        1,
        encodeTiffInts([level.height], TiffType.long, order),
      ),
      _PendingTag(
        258,
        TiffType.short,
        3,
        encodeTiffInts([8, 8, 8], TiffType.short, order),
      ),
      _PendingTag(
        259,
        TiffType.short,
        1,
        encodeTiffInts([7], TiffType.short, order),
      ), // new-style JPEG
      _PendingTag(
        262,
        TiffType.short,
        1,
        encodeTiffInts([6], TiffType.short, order),
      ), // YCbCr
      if (descBytes != null)
        _PendingTag(270, TiffType.ascii, descBytes.length, descBytes),
      _PendingTag(
        277,
        TiffType.short,
        1,
        encodeTiffInts([3], TiffType.short, order),
      ),
      _PendingTag(
        322,
        TiffType.long,
        1,
        encodeTiffInts([level.tileWidth], TiffType.long, order),
      ),
      _PendingTag(
        323,
        TiffType.long,
        1,
        encodeTiffInts([level.tileLength], TiffType.long, order),
      ),
      _PendingTag(324, TiffType.long8, tileCount, null), // TileOffsets
      _PendingTag(325, TiffType.long, tileCount, null), // TileByteCounts
    ]);
  }

  for (final image in associatedImages) {
    final descBytes = image.imageDescription == null
        ? null
        : Uint8List.fromList([...utf8.encode(image.imageDescription!), 0]);

    planIfd([
      _PendingTag(
        256,
        TiffType.long,
        1,
        encodeTiffInts([image.width], TiffType.long, order),
      ),
      _PendingTag(
        257,
        TiffType.long,
        1,
        encodeTiffInts([image.height], TiffType.long, order),
      ),
      _PendingTag(
        258,
        TiffType.short,
        image.bitsPerSample.length,
        encodeTiffInts(image.bitsPerSample, TiffType.short, order),
      ),
      _PendingTag(
        259,
        TiffType.short,
        1,
        encodeTiffInts([image.compression], TiffType.short, order),
      ),
      if (image.photometricInterpretation != -1)
        _PendingTag(
          262,
          TiffType.short,
          1,
          encodeTiffInts(
            [image.photometricInterpretation],
            TiffType.short,
            order,
          ),
        ),
      if (descBytes != null)
        _PendingTag(270, TiffType.ascii, descBytes.length, descBytes),
      _PendingTag(273, TiffType.long8, image.stripCount, null), // StripOffsets
      _PendingTag(
        277,
        TiffType.short,
        1,
        encodeTiffInts([image.samplesPerPixel], TiffType.short, order),
      ),
      _PendingTag(
        278,
        TiffType.long,
        1,
        encodeTiffInts([image.rowsPerStrip], TiffType.long, order),
      ),
      _PendingTag(
        279,
        TiffType.long,
        image.stripCount,
        null,
      ), // StripByteCounts
      _PendingTag(
        317,
        TiffType.short,
        1,
        encodeTiffInts([image.predictor], TiffType.short, order),
      ),
      if (image.jpegTables != null && image.jpegTables!.isNotEmpty)
        _PendingTag(
          347,
          TiffType.undefined,
          image.jpegTables!.length,
          image.jpegTables,
        ),
    ]);
  }

  final out = Uint8List(pos);
  final data = ByteData.sublistView(out);

  out[0] = 0x49;
  out[1] = 0x49; // 'II' — little-endian
  data.setUint16(2, 43, order); // BigTIFF magic
  data.setUint16(4, 8, order); // offset byte size
  data.setUint16(6, 0, order); // reserved
  data.setUint64(8, ifdOffsets.isEmpty ? 0 : ifdOffsets[0], order);

  final patches = <PyramidLevelPatch>[];
  final associatedPatches = <AssociatedImagePatch>[];
  for (var i = 0; i < ifdPlans.length; i++) {
    final plan = ifdPlans[i];
    final ifdBase = ifdOffsets[i];
    data.setUint64(ifdBase, plan.tags.length, order);

    var entryPos = ifdBase + dirCountFieldSize;
    int? tileOffsetsValuePos;
    int? tileByteCountsValuePos;
    int? stripOffsetsValuePos;
    int? stripByteCountsValuePos;
    for (var j = 0; j < plan.tags.length; j++) {
      final tag = plan.tags[j];
      data.setUint16(entryPos, tag.id, order);
      data.setUint16(entryPos + 2, tag.type, order);
      data.setUint64(entryPos + 4, tag.count, order);

      final blobOffset = plan.blobOffsets[j];
      final valuePos = blobOffset ?? (entryPos + 12);
      if (tag.id == 324) tileOffsetsValuePos = valuePos;
      if (tag.id == 325) tileByteCountsValuePos = valuePos;
      if (tag.id == 273) stripOffsetsValuePos = valuePos;
      if (tag.id == 279) stripByteCountsValuePos = valuePos;

      if (blobOffset == null) {
        if (tag.encodedValue != null) {
          out.setRange(
            entryPos + 12,
            entryPos + 12 + tag.encodedValue!.length,
            tag.encodedValue!,
          );
        }
      } else {
        data.setUint64(entryPos + 12, blobOffset, order);
        if (tag.encodedValue != null) {
          out.setRange(
            blobOffset,
            blobOffset + tag.encodedValue!.length,
            tag.encodedValue!,
          );
        }
      }
      entryPos += entrySize;
    }

    final nextIfdOffset = i + 1 < ifdPlans.length ? ifdOffsets[i + 1] : 0;
    data.setUint64(entryPos, nextIfdOffset, order);

    if (i < levels.length) {
      patches.add(
        PyramidLevelPatch(
          tileOffsetsValuePos: tileOffsetsValuePos!,
          tileByteCountsValuePos: tileByteCountsValuePos!,
          tileCount: levels[i].tileCount,
        ),
      );
    } else {
      final image = associatedImages[i - levels.length];
      associatedPatches.add(
        AssociatedImagePatch(
          stripOffsetsValuePos: stripOffsetsValuePos!,
          stripByteCountsValuePos: stripByteCountsValuePos!,
          stripCount: image.stripCount,
        ),
      );
    }
  }

  return PyramidHeaderLayout(out, patches, associatedImages: associatedPatches);
}
