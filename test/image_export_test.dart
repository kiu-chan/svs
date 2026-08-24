import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:svs/src/errors.dart';
import 'package:svs/src/render/image_export.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

/// A small solid-color test image with a distinct, partially-transparent
/// corner pixel — enough to catch a channel-order mixup (e.g. RGBA vs BGRA)
/// or a dropped alpha channel in the encode path.
Future<ui.Image> _testImage() {
  const w = 4, h = 4;
  final pixels = Uint8List(w * h * 4);
  for (var p = 0; p < w * h; p++) {
    pixels[p * 4] = 200; // R
    pixels[p * 4 + 1] = 100; // G
    pixels[p * 4 + 2] = 50; // B
    pixels[p * 4 + 3] = 255; // A
  }
  // Top-left pixel: distinct and semi-transparent.
  pixels[0] = 10;
  pixels[1] = 20;
  pixels[2] = 30;
  pixels[3] = 128;

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  group('encodeSvsImage', () {
    test('PNG round-trips exact pixels, including alpha', () async {
      final image = await _testImage();
      addTearDown(image.dispose);
      final bytes = await encodeSvsImage(image, format: SvsImageFormat.png);

      final decoded = img.decodePng(bytes)!;
      expect(decoded.width, 4);
      expect(decoded.height, 4);
      final corner = decoded.getPixel(0, 0);
      expect(corner.r, 10);
      expect(corner.g, 20);
      expect(corner.b, 30);
      expect(corner.a, 128);
      final fill = decoded.getPixel(3, 3);
      expect(fill.r, 200);
      expect(fill.g, 100);
      expect(fill.b, 50);
      expect(fill.a, 255);
    });

    test('WebP round-trips exact pixels, including alpha', () async {
      final image = await _testImage();
      addTearDown(image.dispose);
      final bytes = await encodeSvsImage(image, format: SvsImageFormat.webp);

      final decoded = img.decodeWebP(bytes)!;
      final fill = decoded.getPixel(3, 3);
      expect(fill.r, 200);
      expect(fill.g, 100);
      expect(fill.b, 50);
    });

    test('TIFF round-trips exact pixels', () async {
      final image = await _testImage();
      addTearDown(image.dispose);
      final bytes = await encodeSvsImage(image, format: SvsImageFormat.tiff);

      final decoded = img.decodeTiff(bytes)!;
      final fill = decoded.getPixel(3, 3);
      expect(fill.r, 200);
      expect(fill.g, 100);
      expect(fill.b, 50);
    });

    test('BMP round-trips exact RGB (no alpha channel)', () async {
      final image = await _testImage();
      addTearDown(image.dispose);
      final bytes = await encodeSvsImage(image, format: SvsImageFormat.bmp);

      final decoded = img.decodeBmp(bytes)!;
      final fill = decoded.getPixel(3, 3);
      expect(fill.r, 200);
      expect(fill.g, 100);
      expect(fill.b, 50);
    });

    test('JPEG round-trips approximate RGB (lossy, no alpha)', () async {
      final image = await _testImage();
      addTearDown(image.dispose);
      final bytes = await encodeSvsImage(
        image,
        format: SvsImageFormat.jpeg,
        quality: 95,
      );

      final decoded = img.decodeJpg(bytes)!;
      final fill = decoded.getPixel(3, 3);
      expect(fill.r, closeTo(200, 10));
      expect(fill.g, closeTo(100, 10));
      expect(fill.b, closeTo(50, 10));
    });

    test('rejects an out-of-range JPEG quality', () async {
      final image = await _testImage();
      addTearDown(image.dispose);
      await expectLater(
        encodeSvsImage(image, format: SvsImageFormat.jpeg, quality: 0),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        encodeSvsImage(image, format: SvsImageFormat.jpeg, quality: 101),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('exportSvsLevel', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('image_export_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    Future<SvsFile> openTestFile({
      required int width,
      required int height,
    }) async {
      final tilesX = (width / 256).ceil();
      final tilesY = (height / 256).ceil();
      final tileCount = tilesX * tilesY;
      final tags = [
        TestTag.ints(256, TiffType.long, [width], Endian.little),
        TestTag.ints(257, TiffType.long, [height], Endian.little),
        TestTag.ints(259, TiffType.short, [7], Endian.little),
        TestTag.ints(322, TiffType.long, [256], Endian.little),
        TestTag.ints(323, TiffType.long, [256], Endian.little),
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
      final bytes = buildTiff(
        bigTiff: false,
        order: Endian.little,
        ifds: [tags],
      );
      final file = File('${tempDir.path}/test.svs');
      await file.writeAsBytes(bytes);
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);
      return svs;
    }

    test('rejects an out-of-range level', () async {
      final svs = await openTestFile(width: 256, height: 256);
      await expectLater(
        exportSvsLevel(svs, level: 3, format: SvsImageFormat.png),
        throwsA(isA<SvsFormatException>()),
      );
    });

    test(
      'refuses to export a level over an explicitly-passed maxPixels limit',
      () async {
        final svs = await openTestFile(width: 512, height: 512);
        await expectLater(
          exportSvsLevel(
            svs,
            level: 0,
            format: SvsImageFormat.png,
            maxPixels: 1000, // 512x512 = 262144 px, well over this
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('has no pixel-count limit by default', () async {
      // 512x512 would have exceeded the maxPixels: 1000 cap above, but with
      // no maxPixels passed at all, it just works.
      final svs = await openTestFile(width: 512, height: 512);
      final bytes = await exportSvsLevel(
        svs,
        level: 0,
        format: SvsImageFormat.png,
      );
      final decoded = img.decodePng(bytes)!;
      expect(decoded.width, 512);
      expect(decoded.height, 512);
    });

    test('exports a level within the safety limit', () async {
      final svs = await openTestFile(width: 64, height: 64);
      final bytes = await exportSvsLevel(
        svs,
        level: 0,
        format: SvsImageFormat.png,
      );
      final decoded = img.decodePng(bytes)!;
      expect(decoded.width, 64);
      expect(decoded.height, 64);
    });

    test('exportSvsLevelToFile writes the same bytes to disk', () async {
      final svs = await openTestFile(width: 64, height: 64);
      final outPath = '${tempDir.path}/level.png';
      final file = await exportSvsLevelToFile(
        svs,
        path: outPath,
        level: 0,
        format: SvsImageFormat.png,
      );
      expect(file.path, outPath);
      final decoded = img.decodePng(await file.readAsBytes())!;
      expect(decoded.width, 64);
      expect(decoded.height, 64);
    });

    test('exportSvsRegionToFile writes the encoded region to disk', () async {
      final svs = await openTestFile(width: 512, height: 512);
      final outPath = '${tempDir.path}/region.png';
      final file = await exportSvsRegionToFile(
        svs,
        path: outPath,
        level: 0,
        x: 0,
        y: 0,
        width: 32,
        height: 32,
        format: SvsImageFormat.png,
      );
      final decoded = img.decodePng(await file.readAsBytes())!;
      expect(decoded.width, 32);
      expect(decoded.height, 32);
    });
  });
}
