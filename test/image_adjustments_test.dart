import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/render/image_adjustments.dart';

void main() {
  group('SvsImageAdjustments', () {
    test('none is identity, has no color filter, and is a no-op', () {
      const adjustments = SvsImageAdjustments.none;
      expect(adjustments.isIdentity, isTrue);
      expect(adjustments.toColorFilter(), isNull);

      final pixels = Uint8List.fromList([10, 20, 30, 128, 200, 210, 220, 255]);
      final before = Uint8List.fromList(pixels);
      adjustments.applyToRgba(pixels);
      expect(pixels, before);
    });

    test('a non-zero parameter is not identity and has a color filter', () {
      const adjustments = SvsImageAdjustments(brightness: 0.2);
      expect(adjustments.isIdentity, isFalse);
      expect(adjustments.toColorFilter(), isNotNull);
    });

    test('brightness shifts RGB up uniformly, leaves alpha untouched', () {
      const adjustments = SvsImageAdjustments(brightness: 0.2);
      final pixels = Uint8List.fromList([100, 100, 100, 77]);
      adjustments.applyToRgba(pixels);
      expect(pixels[0], greaterThan(100));
      expect(pixels[1], greaterThan(100));
      expect(pixels[2], greaterThan(100));
      expect(pixels[3], 77);
    });

    test('negative brightness shifts RGB down', () {
      const adjustments = SvsImageAdjustments(brightness: -0.2);
      final pixels = Uint8List.fromList([100, 100, 100, 255]);
      adjustments.applyToRgba(pixels);
      expect(pixels[0], lessThan(100));
    });

    test('contrast spreads bright and dark pixels further apart', () {
      const adjustments = SvsImageAdjustments(contrast: 0.5);
      final bright = Uint8List.fromList([200, 200, 200, 255]);
      final dark = Uint8List.fromList([50, 50, 50, 255]);
      adjustments.applyToRgba(bright);
      adjustments.applyToRgba(dark);
      expect(bright[0], greaterThan(200));
      expect(dark[0], lessThan(50));
    });

    test('shadows lifts a black pixel toward gray but leaves white at 255', () {
      const adjustments = SvsImageAdjustments(shadows: 1.0);
      final dark = Uint8List.fromList([0, 0, 0, 255]);
      final bright = Uint8List.fromList([255, 255, 255, 255]);
      adjustments.applyToRgba(dark);
      adjustments.applyToRgba(bright);
      expect(dark[0], greaterThan(0));
      expect(bright[0], 255);
    });

    test('highlights pulls a white pixel down but leaves black at 0', () {
      const adjustments = SvsImageAdjustments(highlights: 1.0);
      final dark = Uint8List.fromList([0, 0, 0, 255]);
      final bright = Uint8List.fromList([255, 255, 255, 255]);
      adjustments.applyToRgba(dark);
      adjustments.applyToRgba(bright);
      expect(bright[0], lessThan(255));
      expect(dark[0], 0);
    });

    test('extreme adjustments clamp to the byte range instead of wrapping', () {
      const adjustments = SvsImageAdjustments(brightness: 1.0);
      final pixels = Uint8List.fromList([250, 250, 250, 255]);
      adjustments.applyToRgba(pixels);
      expect(pixels[0], 255);

      const negativeAdjustments = SvsImageAdjustments(brightness: -1.0);
      final darkPixels = Uint8List.fromList([5, 5, 5, 255]);
      negativeAdjustments.applyToRgba(darkPixels);
      expect(darkPixels[0], 0);
    });
  });
}
