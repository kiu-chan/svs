import 'dart:math' as math;

/// Where (and how much) to copy from one decoded tile into a region output
/// buffer — a flat run of [rowCount] rows, each [colCount] pixels, with
/// [srcFirstIndex]/[dstFirstIndex] the pixel index (not byte offset) of row
/// 0's first pixel in the tile/destination buffers respectively, and
/// [srcStride]/[dstStride] the pixel index delta between consecutive rows.
class TileBlitPlan {
  final int rowCount;
  final int colCount;
  final int srcFirstIndex;
  final int srcStride;
  final int dstFirstIndex;
  final int dstStride;

  const TileBlitPlan({
    required this.rowCount,
    required this.colCount,
    required this.srcFirstIndex,
    required this.srcStride,
    required this.dstFirstIndex,
    required this.dstStride,
  });
}

/// Pure geometry for stitching a decoded tile into a cropped region — no
/// I/O, no decoding, so it's unit-testable directly against plain integers.
/// All `tile*`/`clip*` coordinates share one pixel space (a pyramid level's
/// own); [dstOriginX]/[dstOriginY] is that same space's point that lands at
/// pixel (0,0) of the destination buffer, which is [dstStride] pixels wide
/// per row.
///
/// [clipLeft]/[clipTop]/[clipRight]/[clipBottom] is the sub-area that should
/// actually be filled — typically the requested region intersected with the
/// level's own bounds, so a region that hangs off the slide edge (or has a
/// negative origin) only ever reads pixels that exist, leaving the rest of
/// the destination buffer untouched (meant to stay zero/transparent).
///
/// Returns null if the tile and the clip rect don't overlap at all.
TileBlitPlan? planTileBlit({
  required int clipLeft,
  required int clipTop,
  required int clipRight,
  required int clipBottom,
  required int tileLeft,
  required int tileTop,
  required int tileWidth,
  required int tileHeight,
  required int dstOriginX,
  required int dstOriginY,
  required int dstStride,
}) {
  final overlapLeft = math.max(clipLeft, tileLeft);
  final overlapTop = math.max(clipTop, tileTop);
  final overlapRight = math.min(clipRight, tileLeft + tileWidth);
  final overlapBottom = math.min(clipBottom, tileTop + tileHeight);
  if (overlapRight <= overlapLeft || overlapBottom <= overlapTop) return null;

  return TileBlitPlan(
    rowCount: overlapBottom - overlapTop,
    colCount: overlapRight - overlapLeft,
    srcFirstIndex:
        (overlapTop - tileTop) * tileWidth + (overlapLeft - tileLeft),
    srcStride: tileWidth,
    dstFirstIndex:
        (overlapTop - dstOriginY) * dstStride + (overlapLeft - dstOriginX),
    dstStride: dstStride,
  );
}
