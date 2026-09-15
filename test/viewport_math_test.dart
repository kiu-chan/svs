import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/render/viewport_math.dart';
import 'package:svs/src/svs/aperio_tags.dart';
import 'package:svs/src/svs/svs_file.dart';

SvsLevelGeometry _level({
  required int index,
  required int width,
  required int height,
  required double downsample,
}) {
  return SvsLevelGeometry(
    index: index,
    width: width,
    height: height,
    tileWidth: 256,
    tileLength: 256,
    compression: ApCompression.newJpeg,
    downsample: downsample,
  );
}

void main() {
  group('selectLevel', () {
    // A 3-level pyramid with downsamples [1, 4, 16], as a typical Aperio
    // file might have.
    final levels = [
      _level(index: 0, width: 40000, height: 30000, downsample: 1.0),
      _level(index: 1, width: 10000, height: 7500, downsample: 4.0),
      _level(index: 2, width: 2500, height: 1875, downsample: 16.0),
    ];

    final cases = <(double, int)>[
      (1.0, 0), // native zoom: only level 0 avoids upsampling
      (
        2.0,
        0,
      ), // zoomed in past native: still level 0, some upsampling unavoidable
      (
        0.1,
        1,
      ), // level 0 would be 1:1 fine but level 1 also qualifies and is coarser
      (
        0.02,
        2,
      ), // zoomed far out: coarsest level still qualifies, minimizes data
    ];

    for (final (scale, expected) in cases) {
      test('scale=$scale -> level $expected', () {
        expect(selectLevel(levels, scale), expected);
      });
    }

    test('a single-level pyramid always selects level 0', () {
      final single = [
        _level(index: 0, width: 1000, height: 1000, downsample: 1.0),
      ];
      expect(selectLevel(single, 10.0), 0);
      expect(selectLevel(single, 0.01), 0);
    });
  });

  group('computeVisibleTiles', () {
    // 800x600 image, 256px tiles -> a 4x3 tile grid.
    final level0 = _level(index: 0, width: 800, height: 600, downsample: 1.0);

    test('native scale, viewport at the origin', () {
      final tiles = computeVisibleTiles(
        level0,
        const Size(300, 200),
        1.0,
        Offset.zero,
      );
      expect(tiles.level, 0);
      expect(tiles.minTx, 0);
      expect(tiles.maxTx, 1);
      expect(tiles.minTy, 0);
      expect(tiles.maxTy, 0);
    });

    test('prefetch margin expands the range and clamps to the tile grid', () {
      final tiles = computeVisibleTiles(
        level0,
        const Size(100, 100),
        1.0,
        const Offset(500, 500),
        margin: 1,
      );
      expect(tiles.minTx, 0);
      expect(tiles.maxTx, 3); // grid is only 4 wide (indices 0..3)
      expect(tiles.minTy, 0);
      expect(
        tiles.maxTy,
        2,
      ); // clamped down from an unclamped 3; grid is 3 tall (indices 0..2)
    });

    test(
      'a downsampled level maps level-0 viewport coordinates through its downsample',
      () {
        // Level 1: 400x300, downsample 2.0 -> a 2x2 tile grid.
        final level1 = _level(
          index: 1,
          width: 400,
          height: 300,
          downsample: 2.0,
        );
        final tiles = computeVisibleTiles(
          level1,
          const Size(512, 512),
          1.0,
          Offset.zero,
        );
        expect(tiles.minTx, 0);
        expect(tiles.maxTx, 1);
        expect(tiles.minTy, 0);
        expect(tiles.maxTy, 1);
      },
    );

    test(
      'a viewport entirely outside the image clamps to the nearest edge tile',
      () {
        final tiles = computeVisibleTiles(
          level0,
          const Size(100, 100),
          1.0,
          const Offset(10000, 10000),
        );
        expect(tiles.minTx, 3);
        expect(tiles.maxTx, 3);
        expect(tiles.minTy, 2);
        expect(tiles.maxTy, 2);
      },
    );
  });

  group('selectReduction', () {
    final cases = <(double, int)>[
      (1.3, 0), // at the quality bar already: full resolution
      (0.66, 0), // halving would make each pixel 1.32 screen px — too big
      (0.65, 1),
      (0.3, 2),
      (0.1, 3),
      (0.001, 3), // capped at maxReduction
    ];
    for (final (screenPixelsPerTexel, expected) in cases) {
      test('$screenPixelsPerTexel screen px/texel -> shift $expected', () {
        expect(selectReduction(screenPixelsPerTexel), expected);
      });
    }

    test('respects a custom maxReduction', () {
      expect(selectReduction(0.001, maxReduction: 1), 1);
    });
  });

  test('reducedTileExtent rounds up', () {
    expect(reducedTileExtent(240, 0), 240);
    expect(reducedTileExtent(240, 3), 30);
    expect(reducedTileExtent(71, 1), 36);
    expect(reducedTileExtent(1, 3), 1);
  });

  group('tilesNearestFirst', () {
    const range = VisibleTiles(
      level: 0,
      minTx: 0,
      maxTx: 4,
      minTy: 0,
      maxTy: 2,
    );

    int chebyshev((int, int) tile, int cx, int cy) {
      final dx = (tile.$1 - cx).abs();
      final dy = (tile.$2 - cy).abs();
      return dx > dy ? dx : dy;
    }

    test('lists every tile in the range exactly once, nearest ring first', () {
      final tiles = tilesNearestFirst(range, 2.5, 1.5, 1000);
      expect(tiles.toSet(), {
        for (var ty = 0; ty <= 2; ty++)
          for (var tx = 0; tx <= 4; tx++) (tx, ty),
      });
      expect(tiles, hasLength(15));
      expect(tiles.first, (2, 1));
      final rings = tiles.map((t) => chebyshev(t, 2, 1)).toList();
      expect(rings, orderedEquals([...rings]..sort()));
    });

    test('stops at the limit, keeping the nearest tiles', () {
      final tiles = tilesNearestFirst(range, 2.5, 1.5, 9);
      expect(tiles.toSet(), {
        for (var ty = 0; ty <= 2; ty++)
          for (var tx = 1; tx <= 3; tx++) (tx, ty),
      });
    });

    test('skips excluded tiles', () {
      const core = VisibleTiles(
        level: 0,
        minTx: 1,
        maxTx: 3,
        minTy: 0,
        maxTy: 2,
      );
      final tiles = tilesNearestFirst(range, 2.5, 1.5, 1000, exclude: core);
      expect(tiles.toSet(), {(0, 0), (0, 1), (0, 2), (4, 0), (4, 1), (4, 2)});
    });

    test('a center outside the range starts from the nearest edge tile', () {
      final tiles = tilesNearestFirst(range, -50, 99, 1);
      expect(tiles, [(0, 2)]);
    });

    test('cost tracks the limit, not the size of a huge range', () {
      const huge = VisibleTiles(
        level: 0,
        minTx: 0,
        maxTx: 999999,
        minTy: 0,
        maxTy: 999999,
      );
      final stopwatch = Stopwatch()..start();
      final tiles = tilesNearestFirst(huge, 500000, 500000, 1024);
      expect(tiles, hasLength(1024));
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('a non-positive limit returns nothing', () {
      expect(tilesNearestFirst(range, 2, 1, 0), isEmpty);
    });
  });

  group('selectSpan', () {
    final cases = <(double, int)>[
      (78, 0), // a 240 px tile at the coarsest zoom a 4x pyramid allows
      (64, 0),
      (63.9, 1),
      (7.68, 4),
      (0.001, 6), // capped at maxSpan
    ];
    for (final (tileScreenSize, expected) in cases) {
      test('$tileScreenSize px tiles -> span $expected', () {
        expect(selectSpan(tileScreenSize), expected);
      });
    }
  });

  test('spanGeometry coarsens only the tile grid', () {
    const level = SvsLevelGeometry(
      index: 1,
      width: 1000,
      height: 600,
      tileWidth: 256,
      tileLength: 256,
      compression: ApCompression.newJpeg,
      downsample: 4,
    );
    final composites = spanGeometry(level, 2);
    expect((composites.tileWidth, composites.tileLength), (1024, 1024));
    expect((composites.tilesAcrossX, composites.tilesAcrossY), (1, 1));
    expect(
      (composites.index, composites.width, composites.height),
      (1, 1000, 600),
    );
    expect(composites.downsample, 4);
    expect(spanGeometry(level, 0), same(level));
  });
}
