import 'dart:ui';

import '../svs/svs_file.dart';

/// The pyramid level to render at, and which of its tiles are visible.
class VisibleTiles {
  final int level;
  final int minTx;
  final int maxTx;
  final int minTy;
  final int maxTy;

  const VisibleTiles({
    required this.level,
    required this.minTx,
    required this.maxTx,
    required this.minTy,
    required this.maxTy,
  });
}

/// Picks the sharpest pyramid level that doesn't require upsampling more
/// than [maxUpsample]x on screen. [levels] must already be ordered by
/// ascending downsample (index 0 = full resolution) — true for
/// [SvsFile.levels] by construction.
///
/// [scale] is screen pixels per level-0 pixel (1.0 = native size). Each
/// level's stored texel occupies `level.downsample * scale` screen pixels;
/// since downsample increases with level index, that quantity is monotonic
/// in [levels], so the qualifying levels always form a prefix `{0..k}` —
/// this returns the last (coarsest) one that still qualifies, minimizing
/// decoded/streamed data, and falls back to level 0 if even that doesn't
/// qualify (deep zoom-in, where some upsampling is unavoidable).
int selectLevel(
  List<SvsLevelGeometry> levels,
  double scale, {
  double maxUpsample = 1.3,
}) {
  var chosen = 0;
  for (var i = 0; i < levels.length; i++) {
    if (levels[i].downsample * scale <= maxUpsample) {
      chosen = i;
    }
  }
  return chosen;
}

/// The range of tile indices at [level] that intersect a viewport of
/// [viewportSize] logical pixels, given the current pan/zoom transform:
/// [scale] screen pixels per level-0 pixel, and [origin] — the level-0
/// coordinate shown at the viewport's top-left corner. [margin] tiles are
/// added on every side (for prefetching) before clamping to the level's
/// actual tile grid.
VisibleTiles computeVisibleTiles(
  SvsLevelGeometry level,
  Size viewportSize,
  double scale,
  Offset origin, {
  int margin = 0,
}) {
  final level0TopLeft = origin;
  final level0BottomRight =
      origin + Offset(viewportSize.width / scale, viewportSize.height / scale);

  final levelTopLeft = level0TopLeft / level.downsample;
  final levelBottomRight = level0BottomRight / level.downsample;

  final minTx = (levelTopLeft.dx / level.tileWidth).floor() - margin;
  final minTy = (levelTopLeft.dy / level.tileLength).floor() - margin;
  final maxTx = (levelBottomRight.dx / level.tileWidth).floor() + margin;
  final maxTy = (levelBottomRight.dy / level.tileLength).floor() + margin;

  final lastTx = level.tilesAcrossX - 1;
  final lastTy = level.tilesAcrossY - 1;

  return VisibleTiles(
    level: level.index,
    minTx: minTx.clamp(0, lastTx),
    maxTx: maxTx.clamp(0, lastTx),
    minTy: minTy.clamp(0, lastTy),
    maxTy: maxTy.clamp(0, lastTy),
  );
}

/// On-screen size, in logical pixels, below which a level's tiles are merged
/// into composites — see [selectSpan].
const minTileScreenSize = 64.0;

/// How many times over — as a power-of-two shift, per side — to merge a
/// level's tiles into composite tiles so each one spans at least
/// [minScreenSize] screen pixels, given [tileScreenSize], the on-screen size
/// of one of its tiles. Capped at [maxSpan].
///
/// Every tile carries a fixed cost however small it's drawn: a fetch, a
/// decode, a texture, a draw call. A slide whose pyramid is too shallow for
/// the current zoom (a single-level file seen zoomed out, say) would
/// otherwise need thousands of tiles a few pixels across; composites keep
/// the count proportional to the screen instead of the slide. Always 0 for
/// Aperio-sized (240 px or larger) tiles in a pyramid stepped 4x or finer,
/// at any zoom [selectLevel] picks.
int selectSpan(
  double tileScreenSize, {
  double minScreenSize = minTileScreenSize,
  int maxSpan = 6,
}) {
  var span = 0;
  while (span < maxSpan && tileScreenSize * (1 << span) < minScreenSize) {
    span++;
  }
  return span;
}

/// [geometry] with its tile grid coarsened to composites of `2^span` x
/// `2^span` of its tiles (see [selectSpan]) — everything else unchanged, so
/// [computeVisibleTiles] and [tilesNearestFirst] work on composites as-is.
SvsLevelGeometry spanGeometry(SvsLevelGeometry geometry, int span) => span == 0
    ? geometry
    : SvsLevelGeometry(
        index: geometry.index,
        width: geometry.width,
        height: geometry.height,
        tileWidth: geometry.tileWidth << span,
        tileLength: geometry.tileLength << span,
        compression: geometry.compression,
        photometricInterpretation: geometry.photometricInterpretation,
        downsample: geometry.downsample,
      );

/// The deepest decode-time downscale — as a power-of-two shift, so a tile
/// is decoded at `1 / 2^shift` of its stored resolution — that still leaves
/// each decoded pixel no bigger than [maxUpsample] screen pixels, capped at
/// [maxReduction].
///
/// [screenPixelsPerTexel] is `level.downsample * scale`: how many screen
/// pixels one of the chosen level's stored texels spans. [selectLevel]
/// already guarantees that's at most [maxUpsample], but a slide whose
/// pyramid steps are wider than 2x (Aperio's usual 4x, or a single-level
/// file) leaves it far *below* that — decoding every texel then just burns
/// CPU and memory on detail the screen can't show. A reduced decode acts
/// like the missing intermediate pyramid level, at the same quality bar
/// [selectLevel] itself applies.
int selectReduction(
  double screenPixelsPerTexel, {
  double maxUpsample = 1.3,
  int maxReduction = 3,
}) {
  var shift = 0;
  while (shift < maxReduction &&
      screenPixelsPerTexel * (1 << (shift + 1)) <= maxUpsample) {
    shift++;
  }
  return shift;
}

/// A [extent]-pixel tile dimension after a [reduction]-shift reduced decode
/// — rounded up, matching both JPEG2000's reduced-resolution output and the
/// target size this package asks `dart:ui` to decode JPEG tiles at.
int reducedTileExtent(int extent, int reduction) =>
    (extent + (1 << reduction) - 1) >> reduction;

/// Up to [limit] tiles of [range], nearest to ([centerTx], [centerTy]) (in
/// fractional tile units) first — expanding square rings out from the
/// center tile — skipping any inside [exclude].
///
/// Costs O([limit] + ring count), never O(tiles in [range]): a zoomed-out
/// view of a slide with too shallow a pyramid can span tens of thousands of
/// tiles at its only usable level, and enumerating all of them on every
/// viewport change would itself stall the UI.
List<(int, int)> tilesNearestFirst(
  VisibleTiles range,
  double centerTx,
  double centerTy,
  int limit, {
  VisibleTiles? exclude,
}) {
  final result = <(int, int)>[];
  if (limit <= 0) return result;
  final cx = centerTx.floor().clamp(range.minTx, range.maxTx);
  final cy = centerTy.floor().clamp(range.minTy, range.maxTy);
  final maxRadius = [
    cx - range.minTx,
    range.maxTx - cx,
    cy - range.minTy,
    range.maxTy - cy,
  ].reduce((a, b) => a > b ? a : b);

  bool add(int tx, int ty) {
    if (exclude != null &&
        tx >= exclude.minTx &&
        tx <= exclude.maxTx &&
        ty >= exclude.minTy &&
        ty <= exclude.maxTy) {
      return false;
    }
    result.add((tx, ty));
    return result.length >= limit;
  }

  for (var r = 0; r <= maxRadius; r++) {
    final left = (cx - r).clamp(range.minTx, range.maxTx);
    final right = (cx + r).clamp(range.minTx, range.maxTx);
    // Top and bottom rows of the ring (just the center tile when r == 0).
    for (final ty in r == 0 ? [cy] : [cy - r, cy + r]) {
      if (ty < range.minTy || ty > range.maxTy) continue;
      for (var tx = left; tx <= right; tx++) {
        if (add(tx, ty)) return result;
      }
    }
    if (r == 0) continue;
    // Left and right columns, between those rows.
    final top = (cy - r + 1).clamp(range.minTy, range.maxTy);
    final bottom = (cy + r - 1).clamp(range.minTy, range.maxTy);
    for (final tx in [cx - r, cx + r]) {
      if (tx < range.minTx || tx > range.maxTx) continue;
      for (var ty = top; ty <= bottom; ty++) {
        if (add(tx, ty)) return result;
      }
    }
  }
  return result;
}
