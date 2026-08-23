import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/errors.dart';
import 'package:svs/src/render/region_decoder.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('region_decoder_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  List<TestTag> tiledLevelTags({required int width, required int height, required int tileSize}) {
    final tilesX = (width / tileSize).ceil();
    final tilesY = (height / tileSize).ceil();
    final tileCount = tilesX * tilesY;
    return [
      TestTag.ints(256, TiffType.long, [width], Endian.little),
      TestTag.ints(257, TiffType.long, [height], Endian.little),
      TestTag.ints(259, TiffType.short, [7], Endian.little), // new-style JPEG
      TestTag.ints(322, TiffType.long, [tileSize], Endian.little),
      TestTag.ints(323, TiffType.long, [tileSize], Endian.little),
      TestTag.ints(
        324,
        TiffType.long,
        List.generate(tileCount, (i) => 10000 + i * 100),
        Endian.little,
      ),
      TestTag.ints(
        325,
        TiffType.long,
        List.generate(tileCount, (i) => 0), // sparse: byte count 0
        Endian.little,
      ),
    ];
  }

  Future<SvsFile> openTestFile() async {
    final bytes = buildTiff(
      bigTiff: false,
      order: Endian.little,
      ifds: [tiledLevelTags(width: 800, height: 600, tileSize: 256)],
    );
    final file = File('${tempDir.path}/test.svs');
    await file.writeAsBytes(bytes);
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);
    return svs;
  }

  test('readSvsRegion rejects an out-of-range level', () async {
    final svs = await openTestFile();
    await expectLater(
      readSvsRegion(svs, level: 5, x: 0, y: 0, width: 10, height: 10),
      throwsA(isA<SvsFormatException>()),
    );
  });

  test('readSvsRegion rejects a non-positive width/height', () async {
    final svs = await openTestFile();
    await expectLater(
      readSvsRegion(svs, level: 0, x: 0, y: 0, width: 0, height: 10),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      readSvsRegion(svs, level: 0, x: 0, y: 0, width: 10, height: -1),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'readSvsRegion rejects a rectangle entirely outside the level',
    () async {
      final svs = await openTestFile();
      await expectLater(
        readSvsRegion(svs, level: 0, x: 10000, y: 10000, width: 50, height: 50),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test(
    'readSvsRegion over an all-sparse area decodes a fully transparent image',
    () async {
      final svs = await openTestFile();
      final image = await readSvsRegion(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
      );
      addTearDown(image.dispose);
      expect(image.width, 64);
      expect(image.height, 64);
      final data = await image.toByteData();
      expect(data, isNotNull);
      // Every byte (RGBA, sparse tile) should be zero.
      expect(data!.buffer.asUint8List().every((b) => b == 0), isTrue);
    },
  );
}
