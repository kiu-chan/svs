import 'dart:math' as math;
import 'dart:ui';

import 'svs_annotation.dart';

/// The physical length and/or area of an [SvsAnnotation], in micrometers
/// (length) and square micrometers (area) — null where that measurement
/// doesn't apply to the shape's [SvsAnnotationShapeType], or where the
/// slide's microns-per-pixel wasn't available.
class SvsMeasurement {
  final double? lengthMicrons;
  final double? areaMicronsSquared;

  const SvsMeasurement({this.lengthMicrons, this.areaMicronsSquared});
}

/// Measures [annotation] using the slide's microns-per-pixel — see
/// `SvsMetadata.mppX`/`mppY`, exposed as `SvsFile.metadata`. Returns nulls
/// throughout if either is null (unmeasurable — most Aperio slides carry
/// both, but not all).
///
/// * [SvsAnnotationShapeType.point]: no measurement.
/// * [SvsAnnotationShapeType.polyline]: `lengthMicrons` is its total path
///   length; no area.
/// * [SvsAnnotationShapeType.rectangle]: `lengthMicrons` is its perimeter,
///   `areaMicronsSquared` its area.
/// * [SvsAnnotationShapeType.polygon]: `lengthMicrons` is its perimeter
///   (including the implicit closing edge), `areaMicronsSquared` its area.
SvsMeasurement measureAnnotation(
  SvsAnnotation annotation, {
  double? mppX,
  double? mppY,
}) {
  if (mppX == null || mppY == null) return const SvsMeasurement();

  switch (annotation.type) {
    case SvsAnnotationShapeType.point:
      return const SvsMeasurement();
    case SvsAnnotationShapeType.polyline:
      if (annotation.points.length < 2) return const SvsMeasurement();
      return SvsMeasurement(
        lengthMicrons: _pathLength(
          annotation.points,
          mppX: mppX,
          mppY: mppY,
          closed: false,
        ),
      );
    case SvsAnnotationShapeType.rectangle:
      if (annotation.points.length < 2) return const SvsMeasurement();
      final rect = annotation.boundingBox;
      final wMicrons = rect.width * mppX;
      final hMicrons = rect.height * mppY;
      return SvsMeasurement(
        lengthMicrons: 2 * (wMicrons + hMicrons),
        areaMicronsSquared: wMicrons * hMicrons,
      );
    case SvsAnnotationShapeType.polygon:
      if (annotation.points.length < 3) return const SvsMeasurement();
      return SvsMeasurement(
        lengthMicrons: _pathLength(
          annotation.points,
          mppX: mppX,
          mppY: mppY,
          closed: true,
        ),
        areaMicronsSquared: _polygonArea(
          annotation.points,
          mppX: mppX,
          mppY: mppY,
        ),
      );
  }
}

double _pathLength(
  List<Offset> points, {
  required double mppX,
  required double mppY,
  required bool closed,
}) {
  var total = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    total += _segmentLength(points[i], points[i + 1], mppX, mppY);
  }
  if (closed) {
    total += _segmentLength(points.last, points.first, mppX, mppY);
  }
  return total;
}

double _segmentLength(Offset a, Offset b, double mppX, double mppY) {
  final dx = (b.dx - a.dx) * mppX;
  final dy = (b.dy - a.dy) * mppY;
  return math.sqrt(dx * dx + dy * dy);
}

/// Shoelace formula, scaling each axis by its own microns-per-pixel before
/// the cross-product sum — correct even when [mppX] != [mppY].
double _polygonArea(
  List<Offset> points, {
  required double mppX,
  required double mppY,
}) {
  var sum = 0.0;
  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    final q = points[(i + 1) % points.length];
    sum += (p.dx * mppX) * (q.dy * mppY) - (q.dx * mppX) * (p.dy * mppY);
  }
  return sum.abs() / 2;
}

/// Formats a length in micrometers as a short human-readable string,
/// switching from µm to mm at 1000 µm (1 mm) — matches the units
/// `SvsImageView`'s own scale bar uses.
String formatMicrons(double microns) {
  if (microns < 1000) return '${microns.toStringAsFixed(1)} µm';
  return '${(microns / 1000).toStringAsFixed(2)} mm';
}

/// Formats an area in square micrometers, switching from µm² to mm² at
/// 1,000,000 µm² (1 mm²).
String formatMicronsSquared(double micronsSquared) {
  if (micronsSquared < 1e6) {
    return '${micronsSquared.toStringAsFixed(1)} µm²';
  }
  return '${(micronsSquared / 1e6).toStringAsFixed(2)} mm²';
}
