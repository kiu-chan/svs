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

  test('TileCacheKey equality is by value', () {
    const a = TileCacheKey(level: 1, tileX: 2, tileY: 3);
    const b = TileCacheKey(level: 1, tileX: 2, tileY: 3);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
