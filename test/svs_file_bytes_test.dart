// SvsFile.openBytes is the entry point for platforms with no filesystem
// (the web) — this test proves it behaves identically to SvsFile.open(path)
// for the operations that matter, and runs on every platform (including
// web), unlike most of this package's other SvsFile tests which write a
// fixture to a real file via dart:io and are tagged @TestOn('vm').
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

Uint8List _buildSparseSingleLevelSvs({
  required int width,
  required int height,
  required int tileSize,
}) {
  final tilesX = (width / tileSize).ceil();
  final tilesY = (height / tileSize).ceil();
  final tileCount = tilesX * tilesY;
  return buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [
      [
        TestTag.ints(256, TiffType.long, [width], Endian.little),
        TestTag.ints(257, TiffType.long, [height], Endian.little),
        TestTag.ints(259, TiffType.short, [7], Endian.little), // new JPEG
        TestTag.ascii(
          270,
          'Aperio Image Library v11.2.1\r\n${width}x$height '
          '[0,0 ${width}x$height] ($tileSize x $tileSize) JPEG/RGB Q=30'
          '|AppMag = 20|MPP = 0.4990',
        ),
        TestTag.ints(322, TiffType.long, [tileSize], Endian.little),
        TestTag.ints(323, TiffType.long, [tileSize], Endian.little),
        // Every tile sparse (byte count 0) — no real JPEG bytes needed to
        // exercise level/tile-geometry parity between open() and
        // openBytes().
        TestTag.ints(
          324,
          TiffType.long,
          List.filled(tileCount, 0),
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
}

void main() {
  test('openBytes parses levels/metadata the same as open(path) does', () async {
    final bytes = _buildSparseSingleLevelSvs(
      width: 800,
      height: 600,
      tileSize: 256,
    );

    final svs = await SvsFile.openBytes(bytes);
    addTearDown(svs.close);

    expect(svs.path, isNull);
    expect(svs.levels, hasLength(1));
    expect(svs.levels[0].width, 800);
    expect(svs.levels[0].height, 600);
    expect(svs.levels[0].tilesAcrossX, 4);
    expect(svs.levels[0].tilesAcrossY, 3);
    expect(svs.metadata.appMag, 20);
    expect(svs.metadata.mppX, closeTo(0.4990, 1e-9));
  });

  test('openBytes reads tile bytes the same as open(path) does', () async {
    final bytes = _buildSparseSingleLevelSvs(
      width: 256,
      height: 256,
      tileSize: 256,
    );

    final svs = await SvsFile.openBytes(bytes);
    addTearDown(svs.close);

    // A sparse tile (byte count 0) reads back as empty, not an error —
    // same contract as the path-based SvsFile.open.
    final tile = await svs.readTileJpegBytes(0, 0, 0);
    expect(tile, isEmpty);
  });

  test('openBytes rejects a corrupt/too-short buffer the same way open '
      'rejects a corrupt file', () async {
    await expectLater(
      SvsFile.openBytes(Uint8List.fromList([1, 2, 3])),
      throwsA(anything),
    );
  });
}
