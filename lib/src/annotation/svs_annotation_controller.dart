import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'svs_annotation.dart';

/// Which shape (if any) drawing gestures on an [SvsImageView] currently
/// build. [none] leaves the view in its normal pan/zoom/select mode.
enum SvsAnnotationDrawMode {
  /// Not drawing: gestures pan, zoom and select as usual.
  none,

  /// A tap commits a [SvsAnnotationShapeType.point] where it landed.
  point,

  /// A single-finger press-drag-release draws a
  /// [SvsAnnotationShapeType.rectangle], so that drag no longer pans.
  rectangle,

  /// Each tap adds a vertex; [SvsAnnotationController.finishPath] commits
  /// the [SvsAnnotationShapeType.polyline].
  polyline,

  /// Each tap adds a vertex; [SvsAnnotationController.finishPath] commits
  /// the [SvsAnnotationShapeType.polygon].
  polygon,
}

/// Owns the annotations drawn over an [SvsImageView] and the interactive
/// state of drawing a new one. Pass the same controller to [SvsImageView] to
/// render its annotations and let pointer gestures build new shapes while
/// [drawMode] isn't [SvsAnnotationDrawMode.none]:
///
/// * [SvsAnnotationDrawMode.point]: a tap commits a point immediately.
/// * [SvsAnnotationDrawMode.rectangle]: press-drag-release draws a rectangle.
/// * [SvsAnnotationDrawMode.polyline] / [SvsAnnotationDrawMode.polygon]:
///   each tap adds a vertex; call [finishPath] (e.g. from a "Done" button in
///   the host app) to commit it.
///
/// Panning and pinch-zoom keep working normally in every mode except
/// [SvsAnnotationDrawMode.rectangle], where a single-finger drag draws
/// instead — switch back to [SvsAnnotationDrawMode.none] (or another
/// tap/path mode) to pan again.
///
/// All coordinates — [SvsAnnotation.points] and every method below — are in
/// the slide's level-0 pixel space, not screen pixels, so they stay valid
/// across pan and zoom.
class SvsAnnotationController extends ChangeNotifier {
  final List<SvsAnnotation> _annotations;

  /// Style applied to annotations created via the draw gestures below.
  ///
  /// Changing one affects the next annotation drawn and the current
  /// [draft] preview, and leaves annotations already committed alone.
  Color drawColor;

  /// The [SvsAnnotation.strokeWidth] given to annotations drawn from here
  /// on, in screen (logical) pixels.
  double drawStrokeWidth;

  /// The [SvsAnnotation.filled] flag given to rectangles and polygons
  /// drawn from here on.
  bool drawFilled;

  /// Creates a controller holding a copy of [initial], with the drawing
  /// style the other arguments give.
  ///
  /// As a [ChangeNotifier], it should be disposed when the widget that owns
  /// it is.
  SvsAnnotationController({
    List<SvsAnnotation> initial = const [],
    this.drawColor = const Color(0xFFFFEB3B),
    this.drawStrokeWidth = 2,
    this.drawFilled = false,
  }) : _annotations = List.of(initial);

  /// The committed annotations, oldest first — the order they are painted
  /// in, and the reverse of the order [hitTest] considers them.
  ///
  /// The returned list is an unmodifiable view; add and remove through
  /// [add], [remove], [update] and [clear] so listeners are notified.
  List<SvsAnnotation> get annotations => List.unmodifiable(_annotations);

  SvsAnnotationDrawMode _drawMode = SvsAnnotationDrawMode.none;

  /// Which shape drawing gestures currently build.
  ///
  /// Setting it to a different mode discards any draft in progress.
  SvsAnnotationDrawMode get drawMode => _drawMode;

  set drawMode(SvsAnnotationDrawMode mode) {
    if (mode == _drawMode) return;
    _cancelDraft();
    _drawMode = mode;
    notifyListeners();
  }

  String? _selectedId;

  /// The [SvsAnnotation.id] of the selected annotation, or null when
  /// nothing is selected.
  String? get selectedId => _selectedId;

  /// The selected annotation itself, or null when nothing is selected or
  /// the selected id is no longer in [annotations].
  SvsAnnotation? get selected =>
      _selectedId == null ? null : annotationById(_selectedId!);

  SvsAnnotationShapeType? _draftType;
  List<Offset> _draftPoints = [];

  /// The shape currently mid-draw (a rectangle drag in progress, or the
  /// polygon/polyline vertices placed so far), or null when nothing is
  /// mid-draw. [SvsImageView] renders this as a live preview.
  SvsAnnotation? get draft => _draftType == null
      ? null
      : SvsAnnotation(
          type: _draftType!,
          points: _draftPoints,
          color: drawColor,
          strokeWidth: drawStrokeWidth,
          filled: drawFilled,
        );

  /// The annotation with this [SvsAnnotation.id], or null if [annotations]
  /// holds no such annotation.
  SvsAnnotation? annotationById(String id) {
    for (final a in _annotations) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Appends [annotation], putting it on top of the others, and notifies
  /// listeners.
  void add(SvsAnnotation annotation) {
    _annotations.add(annotation);
    notifyListeners();
  }

  /// Removes the annotation with this id, clearing the selection if it was
  /// the selected one. Does nothing if no annotation has that id.
  void remove(String id) {
    _annotations.removeWhere((a) => a.id == id);
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
  }

  /// Replaces the stored annotation that shares [annotation]'s
  /// [SvsAnnotation.id] — as [SvsAnnotation.copyWith] produces — leaving it
  /// where it is in the paint order. Does nothing if that id is not here.
  void update(SvsAnnotation annotation) {
    final i = _annotations.indexWhere((a) => a.id == annotation.id);
    if (i == -1) return;
    _annotations[i] = annotation;
    notifyListeners();
  }

  /// Removes every annotation and clears the selection.
  void clear() {
    _annotations.clear();
    _selectedId = null;
    notifyListeners();
  }

  /// Selects the annotation with this id, or clears the selection when
  /// [id] is null. The selected annotation is painted in the view's
  /// selection colour, with a slightly heavier stroke.
  void select(String? id) {
    if (_selectedId == id) return;
    _selectedId = id;
    notifyListeners();
  }

  /// The topmost (last-added) annotation within [tolerance] level-0 pixels
  /// of [level0Point], or null if none qualify.
  SvsAnnotation? hitTest(Offset level0Point, double tolerance) {
    for (final a in _annotations.reversed) {
      if (a.hitTest(level0Point, tolerance)) return a;
    }
    return null;
  }

  // --- Draw gestures — called by SvsImageView; not normally called directly ---

  /// Begins a rectangle draft at [level0Point]; called by [SvsImageView]
  /// when a drag starts in [SvsAnnotationDrawMode.rectangle].
  void startRectDraft(Offset level0Point) {
    if (_drawMode != SvsAnnotationDrawMode.rectangle) return;
    _draftType = SvsAnnotationShapeType.rectangle;
    _draftPoints = [level0Point, level0Point];
    notifyListeners();
  }

  /// Moves the dragged corner of the rectangle draft to [level0Point],
  /// keeping the corner [startRectDraft] anchored.
  void updateRectDraft(Offset level0Point) {
    if (_draftType != SvsAnnotationShapeType.rectangle) return;
    _draftPoints = [_draftPoints.first, level0Point];
    notifyListeners();
  }

  /// Commits the rectangle draft as an annotation, or drops it if the drag
  /// never left its starting point.
  void commitRectDraft() {
    if (_draftType != SvsAnnotationShapeType.rectangle) return;
    final points = _draftPoints;
    _draftType = null;
    _draftPoints = [];
    if ((points[0] - points[1]).distance == 0) {
      notifyListeners(); // clears the zero-size draft preview
      return;
    }
    add(
      SvsAnnotation(
        type: SvsAnnotationShapeType.rectangle,
        points: points,
        color: drawColor,
        strokeWidth: drawStrokeWidth,
        filled: drawFilled,
      ),
    );
  }

  /// Adds a point annotation at [level0Point]; does nothing unless
  /// [drawMode] is [SvsAnnotationDrawMode.point].
  void commitPoint(Offset level0Point) {
    if (_drawMode != SvsAnnotationDrawMode.point) return;
    add(
      SvsAnnotation(
        type: SvsAnnotationShapeType.point,
        points: [level0Point],
        color: drawColor,
        strokeWidth: drawStrokeWidth,
      ),
    );
  }

  /// Appends a vertex to the polyline or polygon being drawn, starting one
  /// if none is in progress. Does nothing outside the two path draw modes;
  /// [finishPath] commits the result.
  void addPathPoint(Offset level0Point) {
    if (_drawMode != SvsAnnotationDrawMode.polyline &&
        _drawMode != SvsAnnotationDrawMode.polygon) {
      return;
    }
    _draftType = _drawMode == SvsAnnotationDrawMode.polygon
        ? SvsAnnotationShapeType.polygon
        : SvsAnnotationShapeType.polyline;
    _draftPoints = [..._draftPoints, level0Point];
    notifyListeners();
  }

  /// Commits the in-progress polygon/polyline started via [addPathPoint].
  /// Requires at least 2 vertices for a polyline, 3 for a polygon — does
  /// nothing (leaves the draft as-is) if there aren't enough yet.
  void finishPath() {
    final type = _draftType;
    if (type != SvsAnnotationShapeType.polygon &&
        type != SvsAnnotationShapeType.polyline) {
      return;
    }
    final minPoints = type == SvsAnnotationShapeType.polygon ? 3 : 2;
    if (_draftPoints.length < minPoints) return;
    final points = _draftPoints;
    _draftType = null;
    _draftPoints = [];
    add(
      SvsAnnotation(
        type: type!,
        points: points,
        color: drawColor,
        strokeWidth: drawStrokeWidth,
        filled: drawFilled,
      ),
    );
  }

  /// Discards any in-progress draft (rectangle drag or polygon/polyline
  /// vertices) without committing it.
  void cancelDraft() => _cancelDraft();

  void _cancelDraft() {
    if (_draftType == null) return;
    _draftType = null;
    _draftPoints = [];
    notifyListeners();
  }

  // --- Persistence ---

  /// Every annotation as a JSON-safe map, ready for `jsonEncode`.
  List<Map<String, dynamic>> toJsonList() =>
      _annotations.map((a) => a.toJson()).toList();

  /// Replaces the current annotations with those decoded from [json] (as
  /// produced by [toJsonList], typically round-tripped through
  /// `jsonDecode`).
  void loadFromJsonList(List<dynamic> json) {
    _annotations
      ..clear()
      ..addAll(
        json.map((j) => SvsAnnotation.fromJson(j as Map<String, dynamic>)),
      );
    _selectedId = null;
    _cancelDraft();
    notifyListeners();
  }
}
