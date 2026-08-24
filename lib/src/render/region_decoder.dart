import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../errors.dart';
import '../svs/svs_file.dart';
import 'region_blit.dart';

/// Decodes an arbitrary rectangular crop of [level] — [x],[y] top-left and
/// [width]x[height], all in that level's own pixel coordinates (not level-0)
/// — into a single composited [ui.Image], stitching together whichever tiles
/// the rectangle overlaps.
///
/// The requested rectangle may extend past the level's own bounds (or start
/// at a negative [x]/[y]); the out-of-bounds part of the result is left
/// transparent. Throws [ArgumentError] if the rectangle doesn't overlap the
/// level at all, or if [width]/[height] isn't positive.
///
/// [onProgress] (0.0-1.0), if given, is invoked as each overlapping tile is
/// composited into the result.
///
/// Must run on the main isolate, like any other `dart:ui` decode (JPEG tiles
/// go through `dart:ui`'s image codec, which only works there).
Future<ui.Image> readSvsRegion(
  SvsFile svsFile, {
  required int level,
  required int x,
  required int y,
  required int width,
  required int height,
  void Function(double progress)? onProgress,
}) async {
  final outPixels = await readSvsRegionRawRgba(
    svsFile,
    level: level,
    x: x,
    y: y,
    width: width,
    height: height,
    onProgress: onProgress,
  );

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    outPixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Same crop as [readSvsRegion], but returns tightly-packed RGBA8888 bytes
/// (row-major, stride [width] pixels) instead of a decoded [ui.Image] — lets
/// a caller assemble a large region band-by-band (see the streaming pyramid
/// builder in `svs_pyramid_export.dart`) without paying for a `dart:ui`
/// image round-trip per band.
///
/// Same coordinate semantics, out-of-bounds handling, and error behavior as
/// [readSvsRegion]. Must run on the main isolate, for the same reason.
Future<Uint8List> readSvsRegionRawRgba(
  SvsFile svsFile, {
  required int level,
  required int x,
  required int y,
  required int width,
  required int height,
  void Function(double progress)? onProgress,
}) async {
  if (level < 0 || level >= svsFile.levels.length) {
    throw SvsFormatException(
      'Level $level out of range (have ${svsFile.levels.length} levels)',
    );
  }
  if (width <= 0 || height <= 0) {
    throw ArgumentError('width/height must be positive, got ${width}x$height');
  }

  final lvl = svsFile.levels[level];
  final validLeft = x.clamp(0, lvl.width);
  final validTop = y.clamp(0, lvl.height);
  final validRight = (x + width).clamp(0, lvl.width);
  final validBottom = (y + height).clamp(0, lvl.height);
  if (validRight <= validLeft || validBottom <= validTop) {
    throw ArgumentError(
      'Requested region ($x,$y ${width}x$height) does not overlap level '
      '$level (${lvl.width}x${lvl.height})',
    );
  }

  final outPixels = Uint8List(width * height * 4);

  final firstTx = validLeft ~/ lvl.tileWidth;
  final lastTx = (validRight - 1) ~/ lvl.tileWidth;
  final firstTy = validTop ~/ lvl.tileLength;
  final lastTy = (validBottom - 1) ~/ lvl.tileLength;
  final totalTiles = (lastTx - firstTx + 1) * (lastTy - firstTy + 1);
  var tilesDone = 0;

  for (var ty = firstTy; ty <= lastTy; ty++) {
    for (var tx = firstTx; tx <= lastTx; tx++) {
      final tile = await _decodeTileRgba(lvl, tx, ty);
      if (tile != null) {
        final plan = planTileBlit(
          clipLeft: validLeft,
          clipTop: validTop,
          clipRight: validRight,
          clipBottom: validBottom,
          tileLeft: tx * lvl.tileWidth,
          tileTop: ty * lvl.tileLength,
          tileWidth: tile.width,
          tileHeight: tile.height,
          dstOriginX: x,
          dstOriginY: y,
          dstStride: width,
        );
        if (plan != null) {
          for (var row = 0; row < plan.rowCount; row++) {
            final srcStart = (plan.srcFirstIndex + row * plan.srcStride) * 4;
            final dstStart = (plan.dstFirstIndex + row * plan.dstStride) * 4;
            outPixels.setRange(
              dstStart,
              dstStart + plan.colCount * 4,
              tile.bytes,
              srcStart,
            );
          }
        }
      }
      tilesDone++;
      onProgress?.call(tilesDone / totalTiles);
    }
  }

  return outPixels;
}

class _DecodedTile {
  final int width;
  final int height;
  final Uint8List bytes;
  const _DecodedTile(this.width, this.height, this.bytes);
}

/// Decodes tile ([tx], [ty]) of [level] to tightly-packed RGBA8888, or null
/// for a sparse (blank) tile. [_DecodedTile.width]/[height] are the tile's
/// *actual* decoded dimensions — a JPEG tile at the level's right/bottom
/// edge can legally decode smaller than the nominal tile size.
Future<_DecodedTile?> _decodeTileRgba(SvsLevel level, int tx, int ty) async {
  if (level.isJpeg) {
    final jpegBytes = await level.readTileJpegBytes(tx, ty);
    if (jpegBytes.isEmpty) return null;
    final codec = await ui.instantiateImageCodec(jpegBytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    final w = frame.image.width;
    final h = frame.image.height;
    frame.image.dispose();
    if (data == null) return null;
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return _DecodedTile(w, h, bytes);
  }

  final rgba = await level.readTileRgba(tx, ty);
  if (rgba.isEmpty) return null;
  // JP2K tiles are always encoded at the full nominal tile-grid size (unlike
  // JPEG, a boundary tile can't come back cropped).
  return _DecodedTile(level.tileWidth, level.tileLength, rgba);
}
