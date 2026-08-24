import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:svs/src/errors.dart';
import 'package:svs/src/render/region_decoder.dart';
import 'package:svs/src/render/svs_pyramid_export.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

/// Builds a real, decodable single-tile JPEG-compressed source `.svs`
/// fixture: a [size]x[size] image, one [size]x[size] tile, solid-filled with
/// [color]. Unlike the sparse (byte-count-0) fixtures the rest of this
/// package's tests use, this one has genuine tile bytes at a real file
/// offset — needed here because [exportSvsRegionAsSvs] actually decodes its
/// source region via `readSvsRegion`.
///
/// Two-pass layout: `TileOffsets` (a single inline LONG value, since there's
/// only one tile) doesn't change the header's byte length regardless of its
/// value, so the header can be measured once with a placeholder offset, then
/// rebuilt with the tile's real (now-known) offset appended right after it.
Future<File> _buildSingleTileJpegFixture(
  Directory dir,
  String name, {
  required int size,
  required (int, int, int) color,
  String? imageDescription,
}) async {
  final tile = img.Image(width: size, height: size);
  img.fill(tile, color: img.ColorRgb8(color.$1, color.$2, color.$3));
  final tileJpeg = img.encodeJpg(tile, quality: 95);

  List<TestTag> tags(int tileOffset) => [
    TestTag.ints(256, TiffType.long, [size], Endian.little),
    TestTag.ints(257, TiffType.long, [size], Endian.little),
    TestTag.ints(259, TiffType.short, [7], Endian.little), // new-style JPEG
    if (imageDescription != null) TestTag.ascii(270, imageDescription),
    TestTag.ints(322, TiffType.long, [size], Endian.little),
    TestTag.ints(323, TiffType.long, [size], Endian.little),
    TestTag.ints(324, TiffType.long, [tileOffset], Endian.little),
    TestTag.ints(325, TiffType.long, [tileJpeg.length], Endian.little),
  ];

  final headerOnly = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [tags(0)],
  );
  final realOffset = headerOnly.length;
  final header = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [tags(realOffset)],
  );
  // The tile offset is a single inline value (fits in the 4-byte field), so
  // rebuilding with the real offset can't have changed the header's length.
  expect(header.length, realOffset);

  final file = File('${dir.path}/$name');
  await file.writeAsBytes([...header, ...tileJpeg]);
  return file;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('svs_pyramid_export_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('rejects an out-of-range level', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    await expectLater(
      exportSvsRegionAsSvs(svs, level: 3, x: 0, y: 0, width: 64, height: 64),
      throwsA(isA<SvsFormatException>()),
    );
  });

  test('rejects a non-positive tileSize', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    await expectLater(
      exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
        tileSize: 0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'refuses to export a crop over an explicitly-passed maxPixels limit',
    () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (200, 100, 50),
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      await expectLater(
        exportSvsRegionAsSvs(
          svs,
          level: 0,
          x: 0,
          y: 0,
          width: 64,
          height: 64,
          maxPixels: 100, // 64x64 = 4096 px, well over this
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test('has no pixel-count limit by default', () async {
    // 64x64 = 4096 px would have exceeded the old default 100px test cap
    // above, and would have exceeded the old default defaultExportMaxPixels
    // for a big enough crop — with no maxPixels passed at all, it just works.
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final outBytes = await exportSvsRegionAsSvs(
      svs,
      level: 0,
      x: 0,
      y: 0,
      width: 64,
      height: 64,
    );
    expect(outBytes, isNotEmpty);
  });

  test(
    'round-trips a single-level crop: dimensions, pixels, and metadata all survive reopening',
    () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (200, 100, 50),
        imageDescription:
            'Aperio Image Library v11.2.1\r\n'
            '64x64 [0,0 64x64] (64x64) JPEG/RGB Q=30|AppMag = 20|MPP = 0.4990',
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
        tileSize: 256, // bigger than the 64x64 crop -> a single output level
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels, hasLength(1));
      expect(roundTripped.levels.single.width, 64);
      expect(roundTripped.levels.single.height, 64);
      expect(roundTripped.levels.single.isJpeg, isTrue);

      // Metadata parsed back out of the exported file's own ImageDescription.
      expect(roundTripped.metadata.appMag, 20);
      expect(roundTripped.metadata.mppX, closeTo(0.4990, 1e-6));

      final region = await readSvsRegion(
        roundTripped,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
      );
      addTearDown(region.dispose);
      final data = await region.toByteData();
      final pixels = data!.buffer.asUint8List();
      expect(pixels[0], closeTo(200, 10)); // R
      expect(pixels[1], closeTo(100, 10)); // G
      expect(pixels[2], closeTo(50, 10)); // B
    },
  );

  test(
    'round-trips a crop bigger than one tile: multiple pyramid levels are generated',
    () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 512,
        color: (10, 150, 220),
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 512,
        height: 512,
        tileSize:
            256, // -> level 0 = 512x512 (4 tiles), level 1 = 256x256 (1 tile)
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels, hasLength(2));
      expect(roundTripped.levels[0].width, 512);
      expect(roundTripped.levels[0].height, 512);
      expect(roundTripped.levels[1].width, 256);
      expect(roundTripped.levels[1].height, 256);
      expect(roundTripped.levels[1].downsample, closeTo(2.0, 1e-9));

      // The coarsest level is a box-filter downsample of a solid fill, so it
      // should still be (approximately) the same solid color.
      final region = await readSvsRegion(
        roundTripped,
        level: 1,
        x: 0,
        y: 0,
        width: 256,
        height: 256,
      );
      addTearDown(region.dispose);
      final data = await region.toByteData();
      final pixels = data!.buffer.asUint8List();
      expect(pixels[0], closeTo(10, 10));
      expect(pixels[1], closeTo(150, 10));
      expect(pixels[2], closeTo(220, 10));
    },
  );

  test(
    'round-trips a crop spanning several strips/tile-rows and pyramid levels',
    () async {
      // tileSize 128 with an 800x800 source -> level 0 needs 7 strips
      // (128*6 + 32), well beyond the single-strip/single-flush cases the
      // other tests exercise, plus several downsample levels beneath it.
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 800,
        color: (30, 180, 90),
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 800,
        height: 800,
        tileSize: 128,
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels[0].width, 800);
      expect(roundTripped.levels[0].height, 800);
      expect(roundTripped.levels.length, greaterThan(2));

      final coarsest = roundTripped.levels.last;
      expect(coarsest.width, lessThanOrEqualTo(128));
      expect(coarsest.height, lessThanOrEqualTo(128));

      // A solid fill should survive every level's box-filter downsample.
      for (final lvl in roundTripped.levels) {
        final region = await readSvsRegion(
          roundTripped,
          level: lvl.index,
          x: 0,
          y: 0,
          width: lvl.width,
          height: lvl.height,
        );
        addTearDown(region.dispose);
        final data = await region.toByteData();
        final pixels = data!.buffer.asUint8List();
        expect(pixels[0], closeTo(30, 10));
        expect(pixels[1], closeTo(180, 10));
        expect(pixels[2], closeTo(90, 10));
        // Bottom-right corner too, in case a strip/tile boundary got
        // mis-stitched.
        final lastPixel = pixels.length - 4;
        expect(pixels[lastPixel], closeTo(30, 10));
        expect(pixels[lastPixel + 1], closeTo(180, 10));
        expect(pixels[lastPixel + 2], closeTo(90, 10));
      }
    },
  );

  test('onProgress is invoked with increasing values up to 1.0', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 400,
      color: (10, 150, 220),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final progressValues = <double>[];
    await exportSvsRegionAsSvs(
      svs,
      level: 0,
      x: 0,
      y: 0,
      width: 400,
      height: 400,
      tileSize: 128,
      onProgress: progressValues.add,
    );

    expect(progressValues, isNotEmpty);
    for (var i = 1; i < progressValues.length; i++) {
      expect(progressValues[i], greaterThan(progressValues[i - 1]));
    }
    expect(progressValues.last, closeTo(1.0, 1e-9));
  });

  test('exportSvsRegionAsSvsToFile writes the same bytes to disk', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final outPath = '${tempDir.path}/out.svs';
    final outFile = await exportSvsRegionAsSvsToFile(
      svs,
      path: outPath,
      level: 0,
      x: 0,
      y: 0,
      width: 64,
      height: 64,
    );
    expect(outFile.path, outPath);

    final roundTripped = await SvsFile.open(outPath);
    addTearDown(roundTripped.close);
    expect(roundTripped.levels.single.width, 64);
    expect(roundTripped.levels.single.height, 64);
  });
}
