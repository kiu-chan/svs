import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/cache/tile_cache.dart';

Future<ui.Image> _makeImage(int side) {
  final pixels = Uint8List(side * side * 4);
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    side,
    side,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('get() returns null for a key never put', () {
    final cache = TileCache(maxBytes: 1000);
    expect(cache.get(const TileCacheKey(level: 0, tileX: 0, tileY: 0)), isNull);
  });

  test(
    'put() then get() returns the same image and tracks byte usage',
    () async {
      final cache = TileCache(maxBytes: 1000);
      final image = await _makeImage(2);
      const key = TileCacheKey(level: 0, tileX: 1, tileY: 2);

      cache.put(key, image, 16);

      expect(cache.get(key), same(image));
      expect(cache.currentBytes, 16);
    },
  );

  test('evicts least-recently-used entries once over budget', () async {
    final cache = TileCache(maxBytes: 30);
    final a = await _makeImage(1);
    final b = await _makeImage(1);
    final c = await _makeImage(1);
    const keyA = TileCacheKey(level: 0, tileX: 0, tileY: 0);
    const keyB = TileCacheKey(level: 0, tileX: 1, tileY: 0);
    const keyC = TileCacheKey(level: 0, tileX: 2, tileY: 0);

    cache.put(keyA, a, 10);
    cache.put(keyB, b, 10);
    cache.put(keyC, c, 10); // exactly at budget, nothing evicted yet
    expect(cache.length, 3);

    cache.get(keyA); // touch A so B becomes the least-recently-used

    final d = await _makeImage(1);
    const keyD = TileCacheKey(level: 0, tileX: 3, tileY: 0);
    cache.put(keyD, d, 10); // pushes 10 bytes over budget -> evicts B

    expect(cache.get(keyB), isNull);
    expect(cache.get(keyA), same(a));
    expect(cache.get(keyC), same(c));
    expect(cache.get(keyD), same(d));
    expect(cache.currentBytes, 30);
  });

  test('clear() disposes every image and resets byte accounting', () async {
    final cache = TileCache(maxBytes: 1000);
    final image = await _makeImage(2);
    const key = TileCacheKey(level: 0, tileX: 0, tileY: 0);
    cache.put(key, image, 16);

    cache.clear();

    expect(cache.currentBytes, 0);
    expect(cache.length, 0);
  });

  test('put() records the reduction and a re-put replaces it', () async {
    final cache = TileCache(maxBytes: 1000);
    const key = TileCacheKey(level: 0, tileX: 0, tileY: 0);
    expect(cache.reductionOf(key), isNull);

    cache.put(key, await _makeImage(1), 4, reduction: 2);
    expect(cache.reductionOf(key), 2);

    cache.put(key, await _makeImage(2), 16);
    expect(cache.reductionOf(key), 0);
    expect(cache.currentBytes, 16);
    expect(cache.length, 1);
  });

  // Both lookup strategies: probing the range's grid (range no bigger than
  // the cache) and scanning the cache's entries (range much bigger).
  for (final (description, maxTx) in [
    ('a small range (grid probe)', 1),
    ('a huge range (entry scan)', 100000),
  ]) {
    test('countInRange/forEachInRange over $description', () async {
      final cache = TileCache(maxBytes: 1000);
      final inRange = [
        const TileCacheKey(level: 1, tileX: 0, tileY: 0),
        const TileCacheKey(level: 1, tileX: 1, tileY: 1),
      ];
      final outOfRange = [
        const TileCacheKey(level: 1, tileX: 0, tileY: 5), // wrong row
        const TileCacheKey(level: 0, tileX: 0, tileY: 0), // wrong level
      ];
      // Out-of-range entries first, so the grid-probe case genuinely has
      // fewer range cells than cache entries.
      for (final key in [...outOfRange, ...inRange]) {
        cache.put(key, await _makeImage(1), 4, reduction: key.tileX);
      }

      expect(cache.countInRange(1, 0, maxTx, 0, 1), 2);

      final visited = <TileCacheKey, int>{};
      cache.forEachInRange(
        1,
        0,
        maxTx,
        0,
        1,
        (key, image, reduction) => visited[key] = reduction,
      );
      expect(visited, {inRange[0]: 0, inRange[1]: 1});
    });
  }

  test('forEachInRange touches visited tiles as most-recently-used', () async {
    final cache = TileCache(maxBytes: 8);
    const keyA = TileCacheKey(level: 0, tileX: 0, tileY: 0);
    const keyB = TileCacheKey(level: 0, tileX: 1, tileY: 0);
    cache.put(keyA, await _makeImage(1), 4);
    cache.put(keyB, await _makeImage(1), 4);

    cache.forEachInRange(0, 0, 0, 0, 0, (_, _, _) {}); // touch A only

    const keyC = TileCacheKey(level: 0, tileX: 2, tileY: 0);
    cache.put(keyC, await _makeImage(1), 4); // evicts B, the LRU one
    expect(cache.contains(keyA), isTrue);
    expect(cache.contains(keyB), isFalse);
  });

  test('span tells a composite apart from the tile at its origin', () async {
    final cache = TileCache(maxBytes: 1000);
    const tile = TileCacheKey(level: 0, tileX: 0, tileY: 0);
    const composite = TileCacheKey(level: 0, tileX: 0, tileY: 0, span: 2);
    expect(tile, isNot(composite));

    cache.put(tile, await _makeImage(1), 4);
    cache.put(composite, await _makeImage(1), 4, reduction: 3);

    expect(cache.length, 2);
    expect(cache.countInRange(0, 0, 0, 0, 0), 1);
    expect(cache.countInRange(0, 0, 0, 0, 0, span: 2), 1);
    expect(cache.reductionOf(composite), 3);
    expect(cache.cachedGroups.toSet(), {(0, 0), (0, 2)});
  });

  test('cachedGroups drops a group once its last tile is gone', () async {
    final cache = TileCache(maxBytes: 4);
    cache.put(
      const TileCacheKey(level: 1, tileX: 0, tileY: 0),
      await _makeImage(1),
      4,
    );
    expect(cache.cachedGroups, [(1, 0)]);

    // Evicts level 1's only tile.
    cache.put(
      const TileCacheKey(level: 0, tileX: 0, tileY: 0),
      await _makeImage(1),
      4,
    );
    expect(cache.cachedGroups, [(0, 0)]);

    cache.clear();
    expect(cache.cachedGroups, isEmpty);
  });

  test('TileCacheKey equality is by value', () {
    const a = TileCacheKey(level: 1, tileX: 2, tileY: 3);
    const b = TileCacheKey(level: 1, tileX: 2, tileY: 3);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
