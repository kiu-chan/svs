import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/render/viewport_math.dart';
import 'package:svs/src/svs/aperio_tags.dart';
import 'package:svs/src/svs/svs_file.dart';

SvsLevelGeometry _level({required int index, required int width, required int height, required double downsample}) {
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
      (2.0, 0), // zoomed in past native: still level 0, some upsampling unavoidable
      (0.1, 1), // level 0 would be 1:1 fine but level 1 also qualifies and is coarser
      (0.02, 2), // zoomed far out: coarsest level still qualifies, minimizes data
    ];

    for (final (scale, expected) in cases) {
      test('scale=$scale -> level $expected', () {
        expect(selectLevel(levels, scale), expected);
      });
    }

    test('a single-level pyramid always selects level 0', () {
      final single = [_level(index: 0, width: 1000, height: 1000, downsample: 1.0)];
      expect(selectLevel(single, 10.0), 0);
      expect(selectLevel(single, 0.01), 0);
    });
  });

  group('computeVisibleTiles', () {
    // 800x600 image, 256px tiles -> a 4x3 tile grid.
    final level0 = _level(index: 0, width: 800, height: 600, downsample: 1.0);

    test('native scale, viewport at the origin', () {
      final tiles = computeVisibleTiles(level0, const Size(300, 200), 1.0, Offset.zero);
      expect(tiles.level, 0);
      expect(tiles.minTx, 0);
      expect(tiles.maxTx, 1);
      expect(tiles.minTy, 0);
      expect(tiles.maxTy, 0);
    });

    test('prefetch margin expands the range and clamps to the tile grid', () {
      final tiles = computeVisibleTiles(level0, const Size(100, 100), 1.0, const Offset(500, 500), margin: 1);
      expect(tiles.minTx, 0);
      expect(tiles.maxTx, 3); // grid is only 4 wide (indices 0..3)
      expect(tiles.minTy, 0);
      expect(tiles.maxTy, 2); // clamped down from an unclamped 3; grid is 3 tall (indices 0..2)
    });

    test('a downsampled level maps level-0 viewport coordinates through its downsample', () {
      // Level 1: 400x300, downsample 2.0 -> a 2x2 tile grid.
      final level1 = _level(index: 1, width: 400, height: 300, downsample: 2.0);
      final tiles = computeVisibleTiles(level1, const Size(512, 512), 1.0, Offset.zero);
      expect(tiles.minTx, 0);
      expect(tiles.maxTx, 1);
      expect(tiles.minTy, 0);
      expect(tiles.maxTy, 1);
    });

    test('a viewport entirely outside the image clamps to the nearest edge tile', () {
      final tiles = computeVisibleTiles(level0, const Size(100, 100), 1.0, const Offset(10000, 10000));
      expect(tiles.minTx, 3);
      expect(tiles.maxTx, 3);
      expect(tiles.minTy, 2);
      expect(tiles.maxTy, 2);
    });
  });
}
