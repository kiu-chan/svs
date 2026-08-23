import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/render/region_blit.dart';

void main() {
  group('planTileBlit', () {
    test('a region spanning two tiles splits into matching column ranges', () {
      // Region (100,50)-(400,250) over a 256px tile grid: tile (0,0) covers
      // the left part, tile (1,0) the right part, and their column counts
      // must add up to the region's own width (300).
      final left = planTileBlit(
        clipLeft: 100,
        clipTop: 50,
        clipRight: 400,
        clipBottom: 250,
        tileLeft: 0,
        tileTop: 0,
        tileWidth: 256,
        tileHeight: 256,
        dstOriginX: 100,
        dstOriginY: 50,
        dstStride: 300,
      )!;
      expect(left.rowCount, 200);
      expect(left.colCount, 156);
      expect(left.srcFirstIndex, 12900); // row 50, col 100 into the tile
      expect(left.srcStride, 256);
      expect(left.dstFirstIndex, 0);
      expect(left.dstStride, 300);

      final right = planTileBlit(
        clipLeft: 100,
        clipTop: 50,
        clipRight: 400,
        clipBottom: 250,
        tileLeft: 256,
        tileTop: 0,
        tileWidth: 256,
        tileHeight: 256,
        dstOriginX: 100,
        dstOriginY: 50,
        dstStride: 300,
      )!;
      expect(right.rowCount, 200);
      expect(right.colCount, 144);
      expect(right.srcFirstIndex, 12800); // row 50, col 0 into the tile
      expect(right.dstFirstIndex, 156); // right after `left`'s columns

      expect(left.colCount + right.colCount, 300); // covers the full width
    });

    test('a tile the region rect does not reach at all returns null', () {
      final plan = planTileBlit(
        clipLeft: 100,
        clipTop: 50,
        clipRight: 400,
        clipBottom: 250,
        tileLeft: 0,
        tileTop: 256, // starts below clipBottom (250)
        tileWidth: 256,
        tileHeight: 256,
        dstOriginX: 100,
        dstOriginY: 50,
        dstStride: 300,
      );
      expect(plan, isNull);
    });

    test('an edge tile smaller than the nominal tile size clips correctly', () {
      // Real JPEG boundary tiles can decode smaller than the level's
      // nominal tile size (e.g. 100x256 instead of 256x256).
      final plan = planTileBlit(
        clipLeft: 0,
        clipTop: 0,
        clipRight: 500,
        clipBottom: 500,
        tileLeft: 256,
        tileTop: 0,
        tileWidth: 100,
        tileHeight: 256,
        dstOriginX: 0,
        dstOriginY: 0,
        dstStride: 500,
      )!;
      expect(plan.colCount, 100); // bounded by the tile's actual width
      expect(plan.rowCount, 256);
    });

    test(
      'a region hanging off the negative edge offsets into the destination buffer',
      () {
        // Requesting x=-50 means the first 50 destination columns should
        // stay untouched (transparent padding) — the blit starts at column
        // 50 of the destination row.
        final plan = planTileBlit(
          clipLeft: 0,
          clipTop: 0,
          clipRight: 250,
          clipBottom: 100,
          tileLeft: 0,
          tileTop: 0,
          tileWidth: 256,
          tileHeight: 256,
          dstOriginX: -50,
          dstOriginY: 0,
          dstStride: 300,
        )!;
        expect(plan.colCount, 250);
        expect(plan.srcFirstIndex, 0);
        expect(plan.dstFirstIndex, 50);
      },
    );

    test('a fully-contained tile copies its whole intersecting area', () {
      final plan = planTileBlit(
        clipLeft: 0,
        clipTop: 0,
        clipRight: 256,
        clipBottom: 256,
        tileLeft: 0,
        tileTop: 0,
        tileWidth: 256,
        tileHeight: 256,
        dstOriginX: 0,
        dstOriginY: 0,
        dstStride: 256,
      )!;
      expect(plan.rowCount, 256);
      expect(plan.colCount, 256);
      expect(plan.srcFirstIndex, 0);
      expect(plan.dstFirstIndex, 0);
    });
  });
}
