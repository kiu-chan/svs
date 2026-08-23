import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/cache/disk_tile_cache.dart';
import 'package:svs/src/cache/tile_cache.dart';

Uint8List _pixels(int width, int height, int seed) {
  final bytes = Uint8List(width * height * 4);
  final rand = Random(seed);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = rand.nextInt(256);
  }
  return bytes;
}

Future<Uint8List> _imageToRgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('disk_tile_cache_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('get() returns null for a key never put', () async {
    final cache = await DiskTileCache.open(tempDir);
    final image = await cache.get(
      const TileCacheKey(level: 0, tileX: 0, tileY: 0),
    );
    expect(image, isNull);
  });

  test('put() then get() round-trips exact pixels and dimensions', () async {
    final cache = await DiskTileCache.open(tempDir);
    const key = TileCacheKey(level: 0, tileX: 1, tileY: 2);
    final original = _pixels(4, 3, 42);

    await cache.put(key, original, 4, 3);
    final image = await cache.get(key);

    expect(image, isNotNull);
    expect(image!.width, 4);
    expect(image.height, 3);
    expect(await _imageToRgba(image), original);
  });

  test('put() writes a file under the directory and tracks byte usage', () async {
    final cache = await DiskTileCache.open(tempDir);
    const key = TileCacheKey(level: 0, tileX: 0, tileY: 0);
    final bytes = _pixels(2, 2, 1);

    await cache.put(key, bytes, 2, 2);

    expect(cache.contains(key), isTrue);
    expect(cache.length, 1);
    expect(cache.currentBytes, bytes.length + 8); // + 8-byte header
    final files = await tempDir.list().toList();
    expect(files, hasLength(1));
  });

  test('evicts least-recently-used entries once over budget', () async {
    // Each 1x1 RGBA tile is 4 + 8 header = 12 bytes; budget for 2 tiles.
    final cache = await DiskTileCache.open(tempDir, maxBytes: 24);
    const keyA = TileCacheKey(level: 0, tileX: 0, tileY: 0);
    const keyB = TileCacheKey(level: 0, tileX: 1, tileY: 0);
    const keyC = TileCacheKey(level: 0, tileX: 2, tileY: 0);

    await cache.put(keyA, _pixels(1, 1, 1), 1, 1);
    await cache.put(keyB, _pixels(1, 1, 2), 1, 1);
    expect(cache.length, 2);

    await cache.get(keyA); // touch A so B becomes least-recently-used

    await cache.put(keyC, _pixels(1, 1, 3), 1, 1); // pushes B out

    expect(cache.contains(keyB), isFalse);
    expect(cache.contains(keyA), isTrue);
    expect(cache.contains(keyC), isTrue);
    expect(await cache.get(keyB), isNull);
  });

  test(
    'a single tile larger than maxBytes on its own is kept, not '
    'self-evicted the instant it is written',
    () async {
      // A 1x1 tile is 4 + 8 header = 12 bytes, over a 10-byte budget.
      final cache = await DiskTileCache.open(tempDir, maxBytes: 10);
      const key = TileCacheKey(level: 0, tileX: 0, tileY: 0);

      await cache.put(key, _pixels(1, 1, 1), 1, 1);

      expect(cache.contains(key), isTrue);
      expect(cache.currentBytes, 12); // over budget, and that's fine
      expect(await cache.get(key), isNotNull);
    },
  );

  test('open() rebuilds its index from tile files already on disk', () async {
    const key = TileCacheKey(level: 2, tileX: 5, tileY: 7);
    final original = _pixels(3, 3, 99);
    final first = await DiskTileCache.open(tempDir);
    await first.put(key, original, 3, 3);

    final reopened = await DiskTileCache.open(tempDir);

    expect(reopened.contains(key), isTrue);
    expect(reopened.length, 1);
    final image = await reopened.get(key);
    expect(image, isNotNull);
    expect(await _imageToRgba(image!), original);
  });

  test('clear() deletes every file and resets accounting', () async {
    final cache = await DiskTileCache.open(tempDir);
    await cache.put(
      const TileCacheKey(level: 0, tileX: 0, tileY: 0),
      _pixels(1, 1, 1),
      1,
      1,
    );

    await cache.clear();

    expect(cache.length, 0);
    expect(cache.currentBytes, 0);
    expect(await tempDir.list().toList(), isEmpty);
  });
}
