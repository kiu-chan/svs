import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/annotation/svs_annotation.dart';
import 'package:svs/src/annotation/svs_annotation_controller.dart';

void main() {
  group('SvsAnnotation.hitTest', () {
    test('point hits within tolerance, misses outside it', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.point,
        points: const [Offset(100, 100)],
      );
      expect(a.hitTest(const Offset(104, 100), 5), isTrue);
      expect(a.hitTest(const Offset(120, 100), 5), isFalse);
    });

    test('unfilled rectangle hits near its border, not its interior', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.rectangle,
        points: const [Offset(0, 0), Offset(100, 100)],
      );
      expect(a.hitTest(const Offset(0, 50), 3), isTrue); // on left edge
      expect(a.hitTest(const Offset(50, 50), 3), isFalse); // center, unfilled
    });

    test('filled rectangle also hits its interior', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.rectangle,
        points: const [Offset(0, 0), Offset(100, 100)],
        filled: true,
      );
      expect(a.hitTest(const Offset(50, 50), 3), isTrue);
    });

    test('rectangle corners may be given in either order', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.rectangle,
        points: const [Offset(100, 100), Offset(0, 0)],
        filled: true,
      );
      expect(a.boundingBox, const Rect.fromLTRB(0, 0, 100, 100));
      expect(a.hitTest(const Offset(50, 50), 3), isTrue);
    });

    test('polyline hits near a segment, not past its open ends', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.polyline,
        points: const [Offset(0, 0), Offset(100, 0), Offset(100, 100)],
      );
      expect(a.hitTest(const Offset(50, 2), 5), isTrue);
      // The implicit closing edge (last point back to first) doesn't exist
      // for a polyline, so a point near where it would be is a miss.
      expect(a.hitTest(const Offset(50, 50), 5), isFalse);
    });

    test('filled polygon hits its interior via point-in-polygon', () {
      final a = SvsAnnotation(
        type: SvsAnnotationShapeType.polygon,
        points: const [
          Offset(0, 0),
          Offset(100, 0),
          Offset(100, 100),
          Offset(0, 100),
        ],
        filled: true,
      );
      expect(a.hitTest(const Offset(50, 50), 1), isTrue);
      expect(a.hitTest(const Offset(200, 200), 1), isFalse);
    });
  });

  group('SvsAnnotation JSON round-trip', () {
    test('preserves shape, points, style, and label', () {
      final a = SvsAnnotation(
        id: 'ann-1',
        type: SvsAnnotationShapeType.polygon,
        points: const [Offset(1, 2), Offset(3, 4), Offset(5, 6)],
        color: const Color(0xFF00FF00),
        strokeWidth: 3.5,
        filled: true,
        label: 'tumor region',
      );
      final restored = SvsAnnotation.fromJson(a.toJson());
      expect(restored.id, a.id);
      expect(restored.type, a.type);
      expect(restored.points, a.points);
      expect(restored.color, a.color);
      expect(restored.strokeWidth, a.strokeWidth);
      expect(restored.filled, a.filled);
      expect(restored.label, a.label);
    });
  });

  group('SvsAnnotationController rectangle draft', () {
    test('drag lifecycle produces one committed rectangle', () {
      final controller = SvsAnnotationController();
      controller.drawMode = SvsAnnotationDrawMode.rectangle;

      controller.startRectDraft(const Offset(10, 10));
      expect(controller.draft, isNotNull);
      expect(controller.annotations, isEmpty);

      controller.updateRectDraft(const Offset(50, 60));
      expect(controller.draft!.points.last, const Offset(50, 60));

      controller.commitRectDraft();
      expect(controller.draft, isNull);
      expect(controller.annotations, hasLength(1));
      expect(
        controller.annotations.single.type,
        SvsAnnotationShapeType.rectangle,
      );
    });

    test('a zero-size drag commits nothing', () {
      final controller = SvsAnnotationController();
      controller.drawMode = SvsAnnotationDrawMode.rectangle;
      controller.startRectDraft(const Offset(10, 10));
      controller.commitRectDraft();
      expect(controller.annotations, isEmpty);
    });

    test('switching draw mode cancels an in-progress draft', () {
      final controller = SvsAnnotationController();
      controller.drawMode = SvsAnnotationDrawMode.rectangle;
      controller.startRectDraft(const Offset(10, 10));
      controller.drawMode = SvsAnnotationDrawMode.none;
      expect(controller.draft, isNull);
      expect(controller.annotations, isEmpty);
    });
  });

  group('SvsAnnotationController polygon path', () {
    test('finishPath needs at least 3 vertices for a polygon', () {
      final controller = SvsAnnotationController();
      controller.drawMode = SvsAnnotationDrawMode.polygon;
      controller.addPathPoint(const Offset(0, 0));
      controller.addPathPoint(const Offset(10, 0));
      controller.finishPath();
      expect(controller.annotations, isEmpty, reason: 'only 2 vertices so far');

      controller.addPathPoint(const Offset(10, 10));
      controller.finishPath();
      expect(controller.annotations, hasLength(1));
      expect(
        controller.annotations.single.type,
        SvsAnnotationShapeType.polygon,
      );
      expect(controller.draft, isNull);
    });

    test('finishPath needs only 2 vertices for a polyline', () {
      final controller = SvsAnnotationController();
      controller.drawMode = SvsAnnotationDrawMode.polyline;
      controller.addPathPoint(const Offset(0, 0));
      controller.addPathPoint(const Offset(10, 0));
      controller.finishPath();
      expect(controller.annotations, hasLength(1));
      expect(
        controller.annotations.single.type,
        SvsAnnotationShapeType.polyline,
      );
    });
  });

  group('SvsAnnotationController point mode', () {
    test('each tap commits its own point annotation', () {
      final controller = SvsAnnotationController();
      controller.drawMode = SvsAnnotationDrawMode.point;
      controller.commitPoint(const Offset(1, 1));
      controller.commitPoint(const Offset(2, 2));
      expect(controller.annotations, hasLength(2));
      expect(
        controller.annotations.map((a) => a.type),
        everyElement(SvsAnnotationShapeType.point),
      );
    });
  });

  group('SvsAnnotationController selection and hit-testing', () {
    test('hitTest returns the topmost matching annotation', () {
      final controller = SvsAnnotationController();
      controller.add(
        SvsAnnotation(
          id: 'bottom',
          type: SvsAnnotationShapeType.point,
          points: const [Offset(0, 0)],
        ),
      );
      controller.add(
        SvsAnnotation(
          id: 'top',
          type: SvsAnnotationShapeType.point,
          points: const [Offset(0, 0)],
        ),
      );
      final hit = controller.hitTest(const Offset(0, 0), 1);
      expect(hit?.id, 'top');
    });

    test('remove clears selection when the selected annotation is removed', () {
      final controller = SvsAnnotationController();
      controller.add(
        SvsAnnotation(
          id: 'a',
          type: SvsAnnotationShapeType.point,
          points: const [Offset(0, 0)],
        ),
      );
      controller.select('a');
      controller.remove('a');
      expect(controller.selectedId, isNull);
    });
  });

  group('SvsAnnotationController persistence', () {
    test('toJsonList / loadFromJsonList round-trips the annotation set', () {
      final controller = SvsAnnotationController();
      controller.add(
        SvsAnnotation(
          type: SvsAnnotationShapeType.rectangle,
          points: const [Offset(0, 0), Offset(10, 10)],
        ),
      );
      controller.add(
        SvsAnnotation(
          type: SvsAnnotationShapeType.point,
          points: const [Offset(5, 5)],
        ),
      );

      final json = controller.toJsonList();
      final reloaded = SvsAnnotationController();
      reloaded.loadFromJsonList(json);

      expect(reloaded.annotations, hasLength(2));
      expect(
        reloaded.annotations.map((a) => a.type),
        controller.annotations.map((a) => a.type),
      );
    });
  });
}
