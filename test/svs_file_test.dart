import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/errors.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('svs_file_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<String> writeBytes(Uint8List bytes) async {
    final file = File('${tempDir.path}/test.svs');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  List<TestTag> tiledLevelTags({
    required int width,
    required int height,
    required int tileSize,
    String? description,
    int compression = 7,
  }) {
    final tilesX = (width / tileSize).ceil();
    final tilesY = (height / tileSize).ceil();
    final tileCount = tilesX * tilesY;
    final tags = [
      TestTag.ints(256, TiffType.long, [width], Endian.little),
      TestTag.ints(257, TiffType.long, [height], Endian.little),
      TestTag.ints(259, TiffType.short, [compression], Endian.little),
      TestTag.ints(322, TiffType.long, [tileSize], Endian.little),
      TestTag.ints(323, TiffType.long, [tileSize], Endian.little),
      TestTag.ints(324, TiffType.long, List.generate(tileCount, (i) => 10000 + i * 100), Endian.little),
      TestTag.ints(325, TiffType.long, List.generate(tileCount, (i) => 100), Endian.little),
    ];
    if (description != null) tags.add(TestTag.ascii(270, description));
    return tags;
  }

  List<TestTag> associatedImageTags({
    required int width,
    required int height,
    String? description,
    int compression = 7,
  }) {
    final tags = [
      TestTag.ints(256, TiffType.long, [width], Endian.little),
      TestTag.ints(257, TiffType.long, [height], Endian.little),
      TestTag.ints(259, TiffType.short, [compression], Endian.little),
    ];
    if (description != null) tags.add(TestTag.ascii(270, description));
    return tags;
  }

  test('classifies pyramid levels and associated images, parses metadata', () async {
    final bytes = buildTiff(
      bigTiff: false,
      order: Endian.little,
      ifds: [
        tiledLevelTags(
          width: 800,
          height: 600,
          tileSize: 256,
          description:
              'Aperio Image Library v11.2.1\r\n800x600 [0,0 800x600] (256x256) JPEG/RGB Q=30'
              '|AppMag = 20|MPP = 0.4990',
        ),
        tiledLevelTags(width: 400, height: 300, tileSize: 256),
        associatedImageTags(width: 200, height: 150, description: 'label 200x150'),
        associatedImageTags(width: 300, height: 200, description: 'macro image', compression: 1),
        associatedImageTags(width: 100, height: 80),
      ],
    );
    final path = await writeBytes(bytes);

    final svs = await SvsFile.open(path);
    addTearDown(svs.close);

    expect(svs.levels, hasLength(2));
    expect(svs.levels[0].width, 800);
    expect(svs.levels[0].height, 600);
    expect(svs.levels[0].downsample, 1.0);
    expect(svs.levels[0].tilesAcrossX, 4);
    expect(svs.levels[0].tilesAcrossY, 3);
    expect(svs.levels[1].width, 400);
    expect(svs.levels[1].downsample, 2.0);

    expect(svs.metadata.appMag, 20);
    expect(svs.metadata.mppX, closeTo(0.4990, 1e-9));

    expect(svs.associatedImages, hasLength(3));
    expect(svs.associatedImages[0].kind, AssociatedImageKind.label);
    expect(svs.associatedImages[0].isDecodable, isTrue);
    expect(svs.associatedImages[1].kind, AssociatedImageKind.macro);
    expect(svs.associatedImages[1].isDecodable, isFalse); // compression=1, not JPEG
    expect(svs.associatedImages[2].kind, AssociatedImageKind.thumbnail); // no description -> default
  });

  test('rejects a pyramid level with unsupported compression', () async {
    final bytes = buildTiff(
      bigTiff: false,
      order: Endian.little,
      ifds: [
        tiledLevelTags(width: 256, height: 256, tileSize: 256, compression: 6), // old-style JPEG
      ],
    );
    final path = await writeBytes(bytes);
    await expectLater(SvsFile.open(path), throwsA(isA<SvsUnsupportedCompressionError>()));
  });

  test('rejects a file with no tiled levels at all', () async {
    final bytes = buildTiff(
      bigTiff: false,
      order: Endian.little,
      ifds: [associatedImageTags(width: 100, height: 80)],
    );
    final path = await writeBytes(bytes);
    await expectLater(SvsFile.open(path), throwsA(isA<SvsFormatException>()));
  });

  test('rejects a level whose tile table length does not match its tile grid', () async {
    // Only 1 tile's worth of TileOffsets/TileByteCounts for a level whose
    // dimensions actually need a 4x3 grid (12 tiles) — a corrupt-file shape.
    final tags = [
      TestTag.ints(256, TiffType.long, [800], Endian.little),
      TestTag.ints(257, TiffType.long, [600], Endian.little),
      TestTag.ints(259, TiffType.short, [7], Endian.little),
      TestTag.ints(322, TiffType.long, [256], Endian.little),
      TestTag.ints(323, TiffType.long, [256], Endian.little),
      TestTag.ints(324, TiffType.long, [10000], Endian.little),
      TestTag.ints(325, TiffType.long, [100], Endian.little),
    ];
    final bytes = buildTiff(bigTiff: false, order: Endian.little, ifds: [tags]);
    final path = await writeBytes(bytes);

    final svs = await SvsFile.open(path);
    addTearDown(svs.close);
    await expectLater(svs.readTileJpegBytes(0, 0, 0), throwsA(isA<SvsFormatException>()));
  });
}
