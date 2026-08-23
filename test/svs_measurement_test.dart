import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/annotation/svs_annotation.dart';
import 'package:svs/src/annotation/svs_measurement.dart';

void main() {
  group('measureAnnotation', () {
    test('returns nulls when microns-per-pixel is unavailable', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.polyline,
        points: const [Offset(0, 0), Offset(10, 0)],
      );
      final m = measureAnnotation(a, mppX: null, mppY: 0.5);
      expect(m.lengthMicrons, isNull);
      expect(m.areaMicronsSquared, isNull);
    });

    test('point has no measurement', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.point,
        points: const [Offset(0, 0)],
      );
      final m = measureAnnotation(a, mppX: 0.5, mppY: 0.5);
      expect(m.lengthMicrons, isNull);
      expect(m.areaMicronsSquared, isNull);
    });

    test('polyline length sums segment lengths through mpp, no area', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.polyline,
        points: const [Offset(0, 0), Offset(10, 0), Offset(10, 10)],
      );
      final m = measureAnnotation(a, mppX: 2, mppY: 2);
      // 10px * 2 + 10px * 2 = 40 microns.
      expect(m.lengthMicrons, closeTo(40, 1e-9));
      expect(m.areaMicronsSquared, isNull);
    });

    test('rectangle perimeter and area account for anisotropic mpp', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.rectangle,
        points: const [Offset(0, 0), Offset(10, 20)],
      );
      final m = measureAnnotation(a, mppX: 1, mppY: 2);
      // width 10px*1=10um, height 20px*2=40um.
      expect(m.lengthMicrons, closeTo(2 * (10 + 40), 1e-9));
      expect(m.areaMicronsSquared, closeTo(10 * 40, 1e-9));
    });

    test('polygon perimeter includes the implicit closing edge', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.polygon,
        points: const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)],
      );
      final m = measureAnnotation(a, mppX: 1, mppY: 1);
      expect(m.lengthMicrons, closeTo(40, 1e-9)); // 4 sides of 10 microns
      expect(m.areaMicronsSquared, closeTo(100, 1e-9));
    });

    test('polygon area matches known shoelace result for a triangle', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.polygon,
        points: const [Offset(0, 0), Offset(4, 0), Offset(0, 3)],
      );
      final m = measureAnnotation(a, mppX: 1, mppY: 1);
      expect(m.areaMicronsSquared, closeTo(6, 1e-9)); // 0.5 * 4 * 3
    });
  });

  group('formatMicrons', () {
    test('stays in µm below 1000', () {
      expect(formatMicrons(4.5), '4.5 µm');
      expect(formatMicrons(999.9), '999.9 µm');
    });

    test('switches to mm at 1000 µm', () {
      expect(formatMicrons(1000), '1.00 mm');
      expect(formatMicrons(2500), '2.50 mm');
    });
  });

  group('formatMicronsSquared', () {
    test('stays in µm² below 1e6', () {
      expect(formatMicronsSquared(999999), '999999.0 µm²');
    });

    test('switches to mm² at 1e6 µm²', () {
      expect(formatMicronsSquared(2e6), '2.00 mm²');
    });
  });
}
