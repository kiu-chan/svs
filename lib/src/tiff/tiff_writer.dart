// A purpose-built (not generic) tiled-BigTIFF writer: emits exactly the tag
// set `svs_file.dart`'s reader already understands for a pyramid level
// (ImageWidth/ImageLength/BitsPerSample/Compression/
// PhotometricInterpretation/[ImageDescription]/SamplesPerPixel/TileWidth/
// TileLength/TileOffsets/TileByteCounts), with every tile already encoded as
// a standalone JPEG (no shared JPEGTables — `spliceJpegTile` already treats
// tiles without one as self-contained). Internal to this package: the public
// entry point is `render/svs_pyramid_export.dart`.
import 'dart:convert';
import 'dart:typed_data';

import 'tiff_types.dart';

/// One pyramid level's worth of already-encoded tile JPEG bytes, row-major
/// (`tileJpegBytes[ty * tilesAcrossX + tx]`). [imageDescription] is only
/// meaningful (and only actually written) for level 0 — `SvsFile` only ever
/// parses the first level's `ImageDescription` (see `SvsFile._fromTiff`).
class TiffWriterLevel {
  final int width;
  final int height;
  final int tileWidth;
  final int tileLength;
  final String? imageDescription;
  final List<Uint8List> tileJpegBytes;

  const TiffWriterLevel({
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileLength,
    required this.tileJpegBytes,
    this.imageDescription,
  });

  int get tilesAcrossX => (width / tileWidth).ceil();
  int get tilesAcrossY => (height / tileLength).ceil();
}

/// One IFD tag entry pending layout: [count]/[type] are always known up
/// front (needed to compute byte layout before any value is final), but
/// [encodedValue] is null for `TileOffsets` (324) — its value depends on
/// where this level's tile data lands, which is only known once layout is
/// complete, so it's filled in during the write pass instead.
class _PendingTag {
  final int id;
  final int type;
  final int count;
  final Uint8List? encodedValue;

  const _PendingTag(this.id, this.type, this.count, this.encodedValue);

  int get totalBytes => count * tiffTypeSize(type);
}

class _LevelPlan {
  final List<_PendingTag> tags;
  final List<int?>
  blobOffsets; // per tag: null = inline, else out-of-line offset
  final List<int> tileDataOffsets; // per tile
  final List<Uint8List> tileJpegBytes;

  const _LevelPlan({
    required this.tags,
    required this.blobOffsets,
    required this.tileDataOffsets,
    required this.tileJpegBytes,
  });
}

Uint8List _encodeInts(List<int> values, int type, Endian order) {
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
        throw UnsupportedError('_encodeInts does not support type $type');
    }
  }
  return bytes;
}

/// Writes [levels] (level 0 = full resolution, each next one progressively
/// downsampled — order matters, it's the order IFDs are chained in) as a
/// single BigTIFF file: a header, one tiled IFD per level (chained via
/// next-IFD offsets), and every level's tile JPEG bytes.
///
/// Always BigTIFF (64-bit offsets) — simpler than picking classic vs. Big
/// per file, and this package's own reader (`TiffFile`) already handles
/// both, so there's no compatibility reason to prefer classic TIFF here.
Uint8List writeTiledPyramidBigTiff(List<TiffWriterLevel> levels) {
  const order = Endian.little;
  const headerSize = 16;
  const dirCountFieldSize = 8;
  const entrySize = 20; // id(2) + type(2) + count(8) + value/offset(8)
  const valueFieldSize = 8;

  final ifdOffsets = <int>[];
  final levelPlans = <_LevelPlan>[];
  var pos = headerSize;

  for (final level in levels) {
    final tilesX = level.tilesAcrossX;
    final tilesY = level.tilesAcrossY;
    final tileCount = tilesX * tilesY;
    if (level.tileJpegBytes.length != tileCount) {
      throw ArgumentError(
        'Level ${level.width}x${level.height}: expected $tileCount tiles '
        '(${tilesX}x$tilesY), got ${level.tileJpegBytes.length}',
      );
    }

    final byteCounts = [for (final b in level.tileJpegBytes) b.length];
    final descBytes = level.imageDescription == null
        ? null
        : Uint8List.fromList([...utf8.encode(level.imageDescription!), 0]);

    final tags = <_PendingTag>[
      _PendingTag(
        256,
        TiffType.long,
        1,
        _encodeInts([level.width], TiffType.long, order),
      ),
      _PendingTag(
        257,
        TiffType.long,
        1,
        _encodeInts([level.height], TiffType.long, order),
      ),
      _PendingTag(
        258,
        TiffType.short,
        3,
        _encodeInts([8, 8, 8], TiffType.short, order),
      ),
      _PendingTag(
        259,
        TiffType.short,
        1,
        _encodeInts([7], TiffType.short, order),
      ), // new-style JPEG
      _PendingTag(
        262,
        TiffType.short,
        1,
        _encodeInts([6], TiffType.short, order),
      ), // YCbCr
      if (descBytes != null)
        _PendingTag(270, TiffType.ascii, descBytes.length, descBytes),
      _PendingTag(
        277,
        TiffType.short,
        1,
        _encodeInts([3], TiffType.short, order),
      ),
      _PendingTag(
        322,
        TiffType.long,
        1,
        _encodeInts([level.tileWidth], TiffType.long, order),
      ),
      _PendingTag(
        323,
        TiffType.long,
        1,
        _encodeInts([level.tileLength], TiffType.long, order),
      ),
      _PendingTag(
        324,
        TiffType.long8,
        tileCount,
        null,
      ), // TileOffsets: filled at write time
      _PendingTag(
        325,
        TiffType.long,
        tileCount,
        _encodeInts(byteCounts, TiffType.long, order),
      ),
    ];

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

    final tileDataOffsets = <int>[];
    for (final bytes in level.tileJpegBytes) {
      tileDataOffsets.add(pos);
      pos += bytes.length;
      if (pos.isOdd) pos += 1;
    }

    levelPlans.add(
      _LevelPlan(
        tags: tags,
        blobOffsets: blobOffsets,
        tileDataOffsets: tileDataOffsets,
        tileJpegBytes: level.tileJpegBytes,
      ),
    );
  }

  final out = Uint8List(pos);
  final data = ByteData.sublistView(out);

  out[0] = 0x49;
  out[1] = 0x49; // 'II' — little-endian
  data.setUint16(2, 43, order); // BigTIFF magic
  data.setUint16(4, 8, order); // offset byte size
  data.setUint16(6, 0, order); // reserved
  data.setUint64(8, levels.isEmpty ? 0 : ifdOffsets[0], order);

  for (var i = 0; i < levels.length; i++) {
    final plan = levelPlans[i];
    final ifdBase = ifdOffsets[i];
    data.setUint64(ifdBase, plan.tags.length, order);

    var entryPos = ifdBase + dirCountFieldSize;
    for (var j = 0; j < plan.tags.length; j++) {
      final tag = plan.tags[j];
      data.setUint16(entryPos, tag.id, order);
      data.setUint16(entryPos + 2, tag.type, order);
      data.setUint64(entryPos + 4, tag.count, order);

      final valueBytes = tag.id == 324
          ? _encodeInts(plan.tileDataOffsets, TiffType.long8, order)
          : tag.encodedValue!;

      final blobOffset = plan.blobOffsets[j];
      if (blobOffset == null) {
        out.setRange(
          entryPos + 12,
          entryPos + 12 + valueBytes.length,
          valueBytes,
        );
      } else {
        data.setUint64(entryPos + 12, blobOffset, order);
        out.setRange(blobOffset, blobOffset + valueBytes.length, valueBytes);
      }
      entryPos += entrySize;
    }

    final nextIfdOffset = i + 1 < levels.length ? ifdOffsets[i + 1] : 0;
    data.setUint64(entryPos, nextIfdOffset, order);

    for (var t = 0; t < plan.tileJpegBytes.length; t++) {
      final bytes = plan.tileJpegBytes[t];
      out.setRange(
        plan.tileDataOffsets[t],
        plan.tileDataOffsets[t] + bytes.length,
        bytes,
      );
    }
  }

  return out;
}
