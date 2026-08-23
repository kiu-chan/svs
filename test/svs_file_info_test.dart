import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_tag_names.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

void main() {
  group('decodeTiffRationals', () {
    test('decodes unsigned RATIONAL pairs', () {
      final bytes = Uint8List(16);
      final data = ByteData.sublistView(bytes);
      data.setUint32(0, 1, Endian.little);
      data.setUint32(4, 2, Endian.little);
      data.setUint32(8, 300, Endian.little);
      data.setUint32(12, 7, Endian.little);

      final values = decodeTiffRationals(
        bytes,
        TiffType.rational,
        2,
        Endian.little,
      );
      expect(values, [(1, 2), (300, 7)]);
    });

    test('decodes signed SRATIONAL pairs', () {
      final bytes = Uint8List(8);
      final data = ByteData.sublistView(bytes);
      data.setInt32(0, -5, Endian.little);
      data.setInt32(4, 2, Endian.little);

      final values = decodeTiffRationals(
        bytes,
        TiffType.srational,
        1,
        Endian.little,
      );
      expect(values, [(-5, 2)]);
    });
  });

  group('decodeTiffFloats', () {
    test('decodes FLOAT values', () {
      final bytes = Uint8List(8);
      final data = ByteData.sublistView(bytes);
      data.setFloat32(0, 1.5, Endian.little);
      data.setFloat32(4, -2.25, Endian.little);

      final values = decodeTiffFloats(bytes, TiffType.float, 2, Endian.little);
      expect(values[0], closeTo(1.5, 1e-6));
      expect(values[1], closeTo(-2.25, 1e-6));
    });

    test('decodes DOUBLE values', () {
      final bytes = Uint8List(8);
      ByteData.sublistView(bytes).setFloat64(0, 3.14159, Endian.little);

      final values = decodeTiffFloats(
        bytes,
        TiffType.double_,
        1,
        Endian.little,
      );
      expect(values.single, closeTo(3.14159, 1e-9));
    });
  });

  group('tiffTagName', () {
    test('resolves known baseline tags', () {
      expect(tiffTagName(256), 'ImageWidth');
      expect(tiffTagName(322), 'TileWidth');
    });

    test('falls back to Tag<id> for unknown tags', () {
      expect(tiffTagName(65000), 'Tag65000');
    });
  });

  group('full/partial tag reading against a synthetic file', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('svs_file_info_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    Future<SvsFile> openTestFile() async {
      final levelTags = [
        TestTag.ints(256, TiffType.long, [800], Endian.little),
        TestTag.ints(257, TiffType.long, [600], Endian.little),
        TestTag.ints(259, TiffType.short, [7], Endian.little),
        TestTag.ascii(
          270,
          'Aperio Image Library v11.2.1\r\n'
          '800x600 [0,0 800x600] (256x256) JPEG/RGB Q=30|AppMag = 20|MPP = 0.4990',
        ),
        TestTag.ints(322, TiffType.long, [256], Endian.little),
        TestTag.ints(323, TiffType.long, [256], Endian.little),
        TestTag.ints(324, TiffType.long, [10000, 10100, 10200], Endian.little),
        TestTag.ints(325, TiffType.long, [0, 0, 0], Endian.little), // sparse
      ];
      final associatedTags = [
        TestTag.ints(256, TiffType.long, [128], Endian.little),
        TestTag.ints(257, TiffType.long, [96], Endian.little),
        TestTag.ascii(270, 'label mylabel'),
      ];

      final bytes = buildTiff(
        bigTiff: false,
        order: Endian.little,
        ifds: [levelTags, associatedTags],
      );
      final file = File('${tempDir.path}/test.svs');
      await file.writeAsBytes(bytes);
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);
      return svs;
    }

    test('SvsLevel.readAllTags dumps every tag on the level IFD', () async {
      final svs = await openTestFile();
      final tags = await svs.levels.single.readAllTags();

      expect(tags[256], [800]);
      expect(tags[257], [600]);
      expect(tags[259], [7]);
      expect(tags[270], contains('AppMag = 20'));
      expect(tags[322], [256]);
      expect(tags[324], [10000, 10100, 10200]);
    });

    test('SvsLevel.readTags returns only the requested tags', () async {
      final svs = await openTestFile();
      final tags = await svs.levels.single.readTags([256, 257, 9999]);

      expect(tags.keys, unorderedEquals([256, 257]));
      expect(tags[256], [800]);
      expect(tags[257], [600]);
    });

    test('SvsAssociatedImage.readAllTags dumps its own IFD', () async {
      final svs = await openTestFile();
      final tags = await svs.associatedImages.single.readAllTags();

      expect(tags[256], [128]);
      expect(tags[257], [96]);
      expect(tags[270], 'label mylabel');
    });

    test('SvsFile.readInfo assembles a full structured dump', () async {
      final svs = await openTestFile();
      final info = await svs.readInfo();

      expect(info.path, svs.path);
      expect(info.isBigTiff, isFalse);
      expect(info.byteOrder, Endian.little);
      expect(info.metadata.appMag, 20);

      expect(info.levels, hasLength(1));
      expect(info.levels.single.index, 0);
      expect(info.levels.single.tags[256], [800]);
      expect(info.levels.single.namedTags['ImageWidth'], [800]);

      expect(info.associatedImages, hasLength(1));
      expect(info.associatedImages.single.tags[256], [128]);
      expect(info.associatedImages.single.namedTags['ImageWidth'], [128]);
    });
  });
}
