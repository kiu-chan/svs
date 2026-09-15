@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:openjpeg_ffi/openjpeg_ffi.dart';
import 'package:svs/src/cache/tile_cache.dart';
import 'package:svs/src/io/tile_worker_pool.dart';
import 'package:svs/src/render/lod_controller.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

/// A single-level, all-sparse (zero tile byte counts) slide — far too
/// shallow a pyramid for its size, so a zoomed-out viewport spans tens of
/// thousands of its tiles. No tile ever decodes, so this only exercises
/// scheduling, not pixels.
Future<SvsFile> _openHugeSparseSlide(Directory dir) async {
  const side = 64000, tileSize = 256;
  final tilesPerSide = (side / tileSize).ceil();
  final tileCount = tilesPerSide * tilesPerSide;
  final bytes = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [
      [
        TestTag.ints(256, TiffType.long, [side], Endian.little),
        TestTag.ints(257, TiffType.long, [side], Endian.little),
        TestTag.ints(259, TiffType.short, [7], Endian.little),
        TestTag.ints(322, TiffType.long, [tileSize], Endian.little),
        TestTag.ints(323, TiffType.long, [tileSize], Endian.little),
        TestTag.ints(
          324,
          TiffType.long,
          List.filled(tileCount, 16),
          Endian.little,
        ),
        TestTag.ints(
          325,
          TiffType.long,
          List.filled(tileCount, 0),
          Endian.little,
        ),
      ],
    ],
  );
  final file = File('${dir.path}/huge.svs');
  await file.writeAsBytes(bytes);
  return SvsFile.open(file.path);
}

/// A single-level 1024x1024 slide of 16 real 256x256 tiles — JPEG, or
/// JPEG2000 when [jp2k] — so decodes genuinely run.
Future<SvsFile> _openDecodableSlide(Directory dir, {required bool jp2k}) async {
  const side = 1024, tileSize = 256, tileCount = 16;
  final tile = img.Image(width: tileSize, height: tileSize);
  for (final pixel in tile) {
    pixel
      ..r = pixel.x
      ..g = pixel.y
      ..b = 128;
  }
  final tileBytes = jp2k
      ? encodeJ2k(
          tile.getBytes(order: img.ChannelOrder.rgb),
          width: tileSize,
          height: tileSize,
          numComponents: 3,
        )
      : img.encodeJpg(tile, quality: 90);

  List<TestTag> tags(int firstTileOffset) => [
    TestTag.ints(256, TiffType.long, [side], Endian.little),
    TestTag.ints(257, TiffType.long, [side], Endian.little),
    TestTag.ints(259, TiffType.short, [jp2k ? 33005 : 7], Endian.little),
    TestTag.ints(322, TiffType.long, [tileSize], Endian.little),
    TestTag.ints(323, TiffType.long, [tileSize], Endian.little),
    TestTag.ints(324, TiffType.long, [
      for (var i = 0; i < tileCount; i++)
        firstTileOffset + i * tileBytes.length,
    ], Endian.little),
    TestTag.ints(
      325,
      TiffType.long,
      List.filled(tileCount, tileBytes.length),
      Endian.little,
    ),
  ];
  final headerLength = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [tags(0)],
  ).length;
  final header = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [tags(headerLength)],
  );

  final file = File('${dir.path}/${jp2k ? 'jp2k' : 'jpeg'}.svs');
  await file.writeAsBytes([
    ...header,
    for (var i = 0; i < tileCount; i++) ...tileBytes,
  ]);
  return SvsFile.open(file.path);
}

Future<void> _settle(LodController lod) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (lod.inFlightCount > 0 || lod.queuedCount > 0) {
    if (DateTime.now().isAfter(deadline)) fail('LodController never settled');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SvsFile svs;

  const viewport = Size(1920, 1080);
  const fitScale = 1920 / 64000;
  // Tiles ~77 px on screen: plain tiles, no composites.
  const tileScale = 0.3;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lod_controller_test_');
    svs = await _openHugeSparseSlide(tempDir);
  });

  tearDown(() async {
    await svs.close();
    await tempDir.delete(recursive: true);
  });

  LodController callingIsolateController({int maxWantedTiles = 1024}) =>
      LodController(
        svsFile: svs,
        cache: TileCache(),
        maxWantedTiles: maxWantedTiles,
        pool: Future<TileWorkerPool>.error(UnsupportedError('no pool')),
      );

  test('a zoomed-out view of a too-shallow pyramid merges its tiles into '
      'composites instead of wanting every tile it spans', () async {
    final lod = callingIsolateController();
    addTearDown(lod.dispose);

    // ~35,000 of the only level's tiles are on screen at this scale, each
    // under 8 px across. Merged 16x16 into ~123 px composites, the slide
    // is 16x16 composites wide; 9 rows are on screen, plus a prefetch row.
    lod.flushNow(viewport, fitScale, Offset.zero);

    expect(lod.wantedCount, 16 * 10);
  });

  test('maxWantedTiles caps a viewport', () async {
    final lod = callingIsolateController(maxWantedTiles: 50);
    addTearDown(lod.dispose);

    // 8x5 tiles on screen, 10x7 with the prefetch margin.
    lod.flushNow(viewport, 1.0, const Offset(30000, 30000));

    expect(lod.wantedCount, 50);
    expect(lod.inFlightCount + lod.queuedCount, lessThanOrEqualTo(50));
  });

  test('the wanted set also stays within the cache byte budget', () async {
    final lod = LodController(
      svsFile: svs,
      // Full-resolution 256x256 tiles (scale 1.0 needs no reduction) are
      // 262,144 bytes each: 80% of 10 MB fits 32 of them.
      cache: TileCache(maxBytes: 10 * 1024 * 1024),
      pool: Future<TileWorkerPool>.error(UnsupportedError('no pool')),
    );
    addTearDown(lod.dispose);

    lod.flushNow(viewport, 1.0, const Offset(30000, 30000));

    expect(lod.wantedCount, 32);
  });

  test('without a pool, fetches run one at a time', () async {
    final lod = callingIsolateController();
    addTearDown(lod.dispose);
    await Future<void>.delayed(Duration.zero); // let the pool error land

    lod.flushNow(viewport, tileScale, Offset.zero);
    expect(lod.inFlightCount, 1);
    expect(lod.queuedCount, greaterThan(0));

    await _settle(lod);
  });

  test('sparse tiles are remembered, not re-requested on the next '
      'viewport change', () async {
    final lod = callingIsolateController(maxWantedTiles: 64);
    addTearDown(lod.dispose);

    lod.flushNow(viewport, tileScale, Offset.zero);
    await _settle(lod);

    lod.flushNow(viewport, tileScale, Offset.zero);
    expect(lod.inFlightCount, 0);
    expect(lod.queuedCount, 0);
  });

  test('an all-sparse composite is remembered too', () async {
    final lod = callingIsolateController(maxWantedTiles: 2);
    addTearDown(lod.dispose);

    lod.flushNow(viewport, fitScale, Offset.zero);
    await _settle(lod);

    lod.flushNow(viewport, fitScale, Offset.zero);
    expect(lod.inFlightCount, 0);
    expect(lod.queuedCount, 0);
  });

  test(
    'a viewport change replaces the queue instead of appending to it',
    () async {
      final lod = callingIsolateController(maxWantedTiles: 200);
      addTearDown(lod.dispose);
      await Future<void>.delayed(Duration.zero);

      lod.flushNow(viewport, tileScale, Offset.zero);
      lod.flushNow(viewport, tileScale, const Offset(40000, 40000));

      // Only the second viewport's tiles are still pending (plus, at most, the
      // one first-viewport fetch that had already started).
      expect(lod.queuedCount, lessThanOrEqualTo(200));
      await _settle(lod);
    },
  );

  test(
    'with a worker pool, at most two requests per worker are in flight',
    () async {
      final pool = TileWorkerPool.spawn(svs.path!, workerCount: 2);
      final lod = LodController(svsFile: svs, cache: TileCache(), pool: pool);
      addTearDown(lod.dispose);
      await pool;

      lod.flushNow(viewport, tileScale, Offset.zero);
      expect(lod.inFlightCount, lessThanOrEqualTo(4));
      expect(lod.queuedCount, greaterThan(0));

      await _settle(lod);
    },
  );

  group('reduced-resolution decoding', () {
    late SvsFile decodable;

    for (final (name, jp2k) in [('JPEG', false), ('JPEG2000', true)]) {
      test('far enough out, $name tiles are merged into one composite, '
          'with every member in place', () async {
        decodable = await _openDecodableSlide(tempDir, jp2k: jp2k);
        addTearDown(decodable.close);
        final cache = TileCache();
        final lod = LodController(
          svsFile: decodable,
          cache: cache,
          pool: TileWorkerPool.spawn(decodable.path!, workerCount: 2),
        );
        addTearDown(() {
          lod.dispose();
          cache.clear();
        });

        // 0.1 screen px per texel: tiles are 25.6 px on screen, so all 4x4
        // of them make one ~102 px composite, decoded at 1/8 -> 128 px.
        lod.flushNow(const Size(102.4, 102.4), 0.1, Offset.zero);
        await _settle(lod);

        const key = TileCacheKey(level: 0, tileX: 0, tileY: 0, span: 2);
        expect(cache.reductionOf(key), 3);
        ui.Image? composite;
        cache.forEachInRange(
          0,
          0,
          0,
          0,
          0,
          span: 2,
          (_, image, _) => composite = image,
        );
        expect((composite!.width, composite!.height), (128, 128));

        final pixels = (await composite!.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int channel(int x, int y, int c) =>
            pixels.getUint8((y * 128 + x) * 4 + c);
        // Every member's red channel ramps 0-255 across its 32 px and
        // restarts at the next member, so a misplaced member shows up right
        // at the seam.
        expect(channel(31, 10, 0), greaterThan(220)); // tile 0's last texels
        expect(channel(32, 10, 0), lessThan(30)); // tile 1's first texels
        // Tile (1, 2), local texels 64-71 x 48-55.
        expect(channel(40, 70, 0), closeTo(67.5, 12));
        expect(channel(40, 70, 1), closeTo(51.5, 12));
      });

      test('zoomed out, $name tiles decode at 1/4 size and are sharpened '
          'again on zoom-in', () async {
        decodable = await _openDecodableSlide(tempDir, jp2k: jp2k);
        addTearDown(decodable.close);
        final cache = TileCache();
        final lod = LodController(
          svsFile: decodable,
          cache: cache,
          pool: TileWorkerPool.spawn(decodable.path!, workerCount: 2),
        );
        addTearDown(() {
          lod.dispose();
          cache.clear();
        });
        const key = TileCacheKey(level: 0, tileX: 0, tileY: 0);

        // 0.25 screen px per texel (tiles 64 px on screen, so no
        // composites): two halvings still keep each decoded pixel under
        // 1.3 screen px.
        lod.flushNow(const Size(256, 256), 0.25, Offset.zero);
        await _settle(lod);
        expect(cache.reductionOf(key), 2);
        cache.forEachInRange(0, 0, 0, 0, 0, (_, image, _) {
          expect((image.width, image.height), (64, 64));
        });

        lod.flushNow(const Size(256, 256), 1.0, Offset.zero);
        await _settle(lod);
        expect(cache.reductionOf(key), 0);
        cache.forEachInRange(0, 0, 0, 0, 0, (_, image, _) {
          expect((image.width, image.height), (256, 256));
        });
      });
    }
  });
}
