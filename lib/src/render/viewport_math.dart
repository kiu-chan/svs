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
int selectLevel(List<SvsLevelGeometry> levels, double scale, {double maxUpsample = 1.3}) {
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
VisibleTiles computeVisibleTiles(SvsLevelGeometry level, Size viewportSize, double scale, Offset origin, {int margin = 0}) {
  final level0TopLeft = origin;
  final level0BottomRight = origin + Offset(viewportSize.width / scale, viewportSize.height / scale);

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
