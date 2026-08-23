import 'dart:ui';

/// The kind of geometry an [SvsAnnotation] represents.
enum SvsAnnotationShapeType { point, rectangle, polyline, polygon }

/// A user-drawn annotation anchored to a slide, in level-0 pixel coordinates
/// — independent of the current pan/zoom transform, so it stays put as the
/// view moves.
///
/// [points] meaning depends on [type]:
/// * [SvsAnnotationShapeType.point]: exactly one point.
/// * [SvsAnnotationShapeType.rectangle]: exactly two points, any two
///   opposite corners.
/// * [SvsAnnotationShapeType.polyline] / [SvsAnnotationShapeType.polygon]:
///   two or more vertices in order; a polygon's closing edge (last vertex
///   back to the first) is implicit, not repeated in [points].
///
/// [strokeWidth] is in screen (logical) pixels, not slide pixels — an
/// annotation's line looks the same weight at any zoom level, rather than
/// scaling with the slide.
class SvsAnnotation {
  final String id;
  final SvsAnnotationShapeType type;
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  /// Whether a [SvsAnnotationShapeType.rectangle] or
  /// [SvsAnnotationShapeType.polygon] is hit-testable/painted by its
  /// interior, not just its outline. Ignored for [SvsAnnotationShapeType.point]
  /// and [SvsAnnotationShapeType.polyline].
  final bool filled;

  final String? label;

  SvsAnnotation({
    String? id,
    required this.type,
    required this.points,
    this.color = const Color(0xFFFFEB3B),
    this.strokeWidth = 2,
    this.filled = false,
    this.label,
  }) : id = id ?? _generateId(),
       assert(points.isNotEmpty, 'An annotation needs at least one point');

  static int _idCounter = 0;
  static String _generateId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';

  /// The axis-aligned level-0 bounding box of every point in [points].
  Rect get boundingBox {
    var minX = points.first.dx, maxX = points.first.dx;
    var minY = points.first.dy, maxY = points.first.dy;
    for (final p in points.skip(1)) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  SvsAnnotation copyWith({
    List<Offset>? points,
    Color? color,
    double? strokeWidth,
    bool? filled,
    String? label,
  }) {
    return SvsAnnotation(
      id: id,
      type: type,
      points: points ?? this.points,
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      filled: filled ?? this.filled,
      label: label ?? this.label,
    );
  }

  /// Whether [point] (level-0 coordinates) lies within [tolerance] level-0
  /// pixels of this annotation — used for tap hit-testing. [point] and
  /// [polyline] shapes always hit-test against their outline; [rectangle]
  /// and [polygon] additionally count any interior point when [filled].
  bool hitTest(Offset point, double tolerance) {
    switch (type) {
      case SvsAnnotationShapeType.point:
        return (point - points.first).distance <= tolerance;
      case SvsAnnotationShapeType.polyline:
        return _hitTestPolyline(points, point, tolerance, closed: false);
      case SvsAnnotationShapeType.rectangle:
        final rect = boundingBox;
        if (filled && rect.contains(point)) return true;
        return _hitTestPolyline(
          _rectCorners(rect),
          point,
          tolerance,
          closed: true,
        );
      case SvsAnnotationShapeType.polygon:
        if (filled && _pointInPolygon(point, points)) return true;
        return _hitTestPolyline(points, point, tolerance, closed: true);
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'points': points.map((p) => [p.dx, p.dy]).toList(),
    'color': color.toARGB32(),
    'strokeWidth': strokeWidth,
    'filled': filled,
    if (label != null) 'label': label,
  };

  factory SvsAnnotation.fromJson(Map<String, dynamic> json) {
    return SvsAnnotation(
      id: json['id'] as String,
      type: SvsAnnotationShapeType.values.byName(json['type'] as String),
      points: (json['points'] as List)
          .map(
            (p) => Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          )
          .toList(),
      color: Color(json['color'] as int),
      strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 2,
      filled: json['filled'] as bool? ?? false,
      label: json['label'] as String?,
    );
  }
}

List<Offset> _rectCorners(Rect r) => [
  r.topLeft,
  r.topRight,
  r.bottomRight,
  r.bottomLeft,
];

bool _hitTestPolyline(
  List<Offset> points,
  Offset p,
  double tolerance, {
  required bool closed,
}) {
  if (points.length == 1) return (p - points.first).distance <= tolerance;
  for (var i = 0; i < points.length - 1; i++) {
    if (_distanceToSegment(p, points[i], points[i + 1]) <= tolerance) {
      return true;
    }
  }
  if (closed && points.length > 2) {
    if (_distanceToSegment(p, points.last, points.first) <= tolerance) {
      return true;
    }
  }
  return false;
}

double _distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final abLenSq = ab.dx * ab.dx + ab.dy * ab.dy;
  if (abLenSq == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / abLenSq).clamp(
    0.0,
    1.0,
  );
  final closest = a + ab * t;
  return (p - closest).distance;
}

/// Standard ray-casting point-in-polygon test.
bool _pointInPolygon(Offset p, List<Offset> vertices) {
  var inside = false;
  for (var i = 0, j = vertices.length - 1; i < vertices.length; j = i++) {
    final vi = vertices[i];
    final vj = vertices[j];
    final intersects =
        ((vi.dy > p.dy) != (vj.dy > p.dy)) &&
        (p.dx < (vj.dx - vi.dx) * (p.dy - vi.dy) / (vj.dy - vi.dy) + vi.dx);
    if (intersects) inside = !inside;
  }
  return inside;
}
