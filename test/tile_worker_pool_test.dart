@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:svs/src/codec/jpeg2000/j2k_encoder.dart';
import 'package:svs/src/io/tile_worker_pool.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

const _tileSize = 256;

/// A single-level, 2x2-tile JPEG2000 slide with real codestreams (a
/// gradient, so the encoder genuinely uses every wavelet level).
Future<SvsFile> _openJp2kSlide(Directory dir) async {
  final tile = img.Image(width: _tileSize, height: _tileSize);
  for (final pixel in tile) {
    pixel
      ..r = pixel.x
      ..g = pixel.y
      ..b = 128;
  }
  final codestream = encodeJ2k(
    tile.getBytes(order: img.ChannelOrder.rgb),
    width: _tileSize,
    height: _tileSize,
    numComponents: 3,
  );

  const side = _tileSize * 2;
  List<TestTag> tags(int firstTileOffset) => [
    TestTag.ints(256, TiffType.long, [side], Endian.little),
    TestTag.ints(257, TiffType.long, [side], Endian.little),
    TestTag.ints(259, TiffType.short, [33005], Endian.little), // JPEG2000
    TestTag.ints(322, TiffType.long, [_tileSize], Endian.little),
    TestTag.ints(323, TiffType.long, [_tileSize], Endian.little),
    TestTag.ints(324, TiffType.long, [
      for (var i = 0; i < 4; i++) firstTileOffset + i * codestream.length,
    ], Endian.little),
    TestTag.ints(
      325,
      TiffType.long,
      List.filled(4, codestream.length),
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

  final file = File('${dir.path}/jp2k.svs');
  await file.writeAsBytes([
    ...header,
    for (var i = 0; i < 4; i++) ...codestream,
  ]);
  return SvsFile.open(file.path);
}

void main() {
  late Directory tempDir;
  late SvsFile svs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tile_worker_pool_test_');
    svs = await _openJp2kSlide(tempDir);
  });

  tearDown(() async {
    await svs.close();
    await tempDir.delete(recursive: true);
  });

  test('readTileRgba decodes at a reduced resolution', () async {
    final rgba = await svs.levels.single.readTileRgba(
      0,
      0,
      reducedResolutionFactor: 2,
    );
    expect(rgba.length, 64 * 64 * 4);

    // The fixture's red/green channels ramp with x/y, so a genuine 1/4-scale
    // decode ramps four times as fast — not the full-size image's top-left
    // corner, or its edge pixels smeared out.
    for (final (x, y) in [(10, 20), (40, 5), (60, 60)]) {
      final i = (y * 64 + x) * 4;
      expect(rgba[i], closeTo(x * 4, 4), reason: 'red at ($x,$y)');
      expect(rgba[i + 1], closeTo(y * 4, 4), reason: 'green at ($x,$y)');
      expect(rgba[i + 2], closeTo(128, 2), reason: 'blue at ($x,$y)');
      expect(rgba[i + 3], 255, reason: 'alpha at ($x,$y)');
    }
  });

  test('fetchTile falls back to full resolution when the codestream has '
      'too few wavelet levels for the requested reduction', () async {
    final result = await fetchTile(svs.levels.single, 1, 1, reduction: 20);
    expect(result.isRgba, isTrue);
    expect(result.reduction, 0);
    expect(result.bytes!.length, _tileSize * _tileSize * 4);
  });

  test('a pool request honors the reduction and reports it back', () async {
    final pool = await TileWorkerPool.spawn(svs.path!, workerCount: 2);
    addTearDown(pool.dispose);
    expect(pool.workerCount, 2);

    final result = await pool
        .requestTile(level: 0, tileX: 1, tileY: 0, reduction: 1)
        .result;
    expect(result.reduction, 1);
    expect(result.bytes!.length, 128 * 128 * 4);
  });

  test('cancelling rejects right away, and the pool keeps serving', () async {
    final pool = await TileWorkerPool.spawn(svs.path!, workerCount: 2);
    addTearDown(pool.dispose);

    final handles = [
      for (var i = 0; i < 8; i++)
        pool.requestTile(level: 0, tileX: i % 2, tileY: (i ~/ 2) % 2),
    ];
    final cancelled = handles.last;
    pool.cancel(cancelled.requestId);
    await expectLater(
      cancelled.result,
      throwsA(isA<TileRequestCancelledException>()),
    );

    for (final handle in handles.take(7)) {
      expect((await handle.result).bytes, isNotNull);
    }
  });
}
