import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../annotation/svs_annotation.dart';
import '../annotation/svs_annotation_controller.dart';
import '../annotation/svs_measurement.dart';
import '../cache/disk_tile_cache.dart';
import '../cache/tile_cache.dart';
import '../svs/svs_file.dart';
import 'associated_image_decoder.dart';
import 'lod_controller.dart';
import 'viewport_math.dart';

/// A pannable, zoomable view of an open [SvsFile]'s resolution pyramid.
///
/// Streams only the tiles needed for the current viewport/zoom level,
/// decoding on demand and caching decoded tiles in [cache] (an internally
/// owned [TileCache] if none is supplied — pass a shared one to reuse
/// decoded tiles across multiple [SvsImageView]s of the same file).
///
/// Does not take ownership of [svsFile]: the caller opened it and must
/// close it, typically after this widget is disposed.
class SvsImageView extends StatefulWidget {
  final SvsFile svsFile;
  final TileCache? cache;

  /// Optional persistent tile cache — when supplied, decoded tiles are read
  /// from here first (skipping the tile fetch and, for JPEG2000 slides, the
  /// wavelet decode) and written back here after a fresh decode, so the
  /// same region loads faster on the next visit — even across app restarts.
  /// Typically opened via `DiskTileCache.open` at a directory scoped to this
  /// specific slide file (different slides must not share a directory).
  /// Left null (the default), tiles are decoded fresh every session.
  final DiskTileCache? diskCache;

  /// How far a level's stored texels may be upsampled on screen before the
  /// next-finer level is chosen instead. See [selectLevel].
  final double maxUpsample;

  /// Screen pixels per level-0 pixel a user may zoom in to.
  final double maxScale;

  /// Extra tiles fetched beyond the visible range on every side, so panning
  /// a short distance doesn't show blank tiles while they decode.
  final int prefetchMargin;

  /// When set, renders its annotations over the slide and routes pointer
  /// gestures to it while [SvsAnnotationController.drawMode] isn't
  /// [SvsAnnotationDrawMode.none] — see that class for the drawing gestures
  /// each mode uses. Left null (the default), the view is pan/zoom only.
  final SvsAnnotationController? annotationController;

  /// Called with the annotation tapped while [annotationController]'s
  /// `drawMode` is [SvsAnnotationDrawMode.none] (null if the tap didn't hit
  /// one). The tapped annotation is also auto-selected on
  /// [annotationController]; use this to react further, e.g. show an editor.
  final ValueChanged<SvsAnnotation?>? onAnnotationTap;

  /// How close (in screen pixels) a tap must land to an annotation's
  /// outline/interior to count as hitting it.
  final double hitTestTolerance;

  /// Whether line/rectangle/polygon annotations (including the one
  /// currently being drawn) show a live physical length/area label, using
  /// [SvsFile.metadata]'s microns-per-pixel. No effect if the slide has no
  /// microns-per-pixel metadata. Ignored if [annotationController] is null.
  final bool showMeasurements;

  const SvsImageView({
    super.key,
    required this.svsFile,
    this.cache,
    this.maxUpsample = 1.3,
    this.maxScale = 4.0,
    this.prefetchMargin = 1,
    this.diskCache,
    this.annotationController,
    this.onAnnotationTap,
    this.hitTestTolerance = 12,
    this.showMeasurements = true,
  });

  @override
  State<SvsImageView> createState() => _SvsImageViewState();
}

class _SvsImageViewState extends State<SvsImageView>
    with WidgetsBindingObserver {
  late final TileCache _cache = widget.cache ?? TileCache();
  bool get _ownsCache => widget.cache == null;

  late final LodController _lod = LodController(
    svsFile: widget.svsFile,
    cache: _cache,
    maxUpsample: widget.maxUpsample,
    prefetchMargin: widget.prefetchMargin,
    diskCache: widget.diskCache,
  );

  Size? _viewportSize;
  bool _initialized = false;
  double _scale = 1;
  double _minScale = 1;
  Offset _origin = Offset.zero;

  double _gestureStartScale = 1;
  Offset _gestureStartOrigin = Offset.zero;
  Offset _gestureStartFocalPoint = Offset.zero;

  ui.Image? _overviewImage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lod.addListener(_onTilesChanged);
    unawaited(_loadOverview());
  }

  void _onTilesChanged() {
    if (mounted) setState(() {});
  }

  /// The OS is telling every app to free memory it doesn't strictly need
  /// right now — decoded tiles are exactly that (cheaply re-fetched later),
  /// so drop them all rather than risk being killed for a cache that's just
  /// a speed optimization.
  @override
  void didHaveMemoryPressure() {
    _cache.clear();
    if (!mounted) return;
    setState(
      () {},
    ); // the tiles just disposed were still on screen — repaint placeholders instead of a stale-image crash
    final viewportSize = _viewportSize;
    // re-fetch what's currently visible
    if (viewportSize != null) {
      _lod.flushNow(viewportSize, _scale, _origin);
    }
  }

  Future<void> _loadOverview() async {
    SvsAssociatedImage? thumbnail;
    for (final associated in widget.svsFile.associatedImages) {
      if (associated.kind == AssociatedImageKind.thumbnail &&
          associated.isDecodable) {
        thumbnail = associated;
        break;
      }
    }
    if (thumbnail == null) return;
    try {
      final image = await decodeAssociatedImage(thumbnail);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _overviewImage = image);
    } catch (_) {
      // No minimap if the thumbnail can't be decoded — not critical.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lod.removeListener(_onTilesChanged);
    _lod.dispose();
    _overviewImage?.dispose();
    if (_ownsCache) _cache.clear();
    super.dispose();
  }

  void _initializeView(Size viewportSize) {
    final level0 = widget.svsFile.levels.first;
    final fitScale = math.min(
      viewportSize.width / level0.width,
      viewportSize.height / level0.height,
    );
    _minScale = fitScale;
    _scale = fitScale;
    final contentWidth = viewportSize.width / _scale;
    final contentHeight = viewportSize.height / _scale;
    _origin = Offset(
      (level0.width - contentWidth) / 2,
      (level0.height - contentHeight) / 2,
    );
    _lod.flushNow(viewportSize, _scale, _origin);
  }

  Offset _toLevel0(Offset screenPoint) => _origin + screenPoint / _scale;

  bool get _isDraftingRect =>
      widget.annotationController?.drawMode == SvsAnnotationDrawMode.rectangle;

  void _onScaleStart(ScaleStartDetails details) {
    final controller = widget.annotationController;
    if (controller != null && _isDraftingRect) {
      controller.startRectDraft(_toLevel0(details.localFocalPoint));
      return;
    }
    _gestureStartScale = _scale;
    _gestureStartOrigin = _origin;
    _gestureStartFocalPoint = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final controller = widget.annotationController;
    if (controller != null && _isDraftingRect && controller.draft != null) {
      controller.updateRectDraft(_toLevel0(details.localFocalPoint));
      return;
    }
    _zoomAndPanTo(
      startScale: _gestureStartScale,
      startOrigin: _gestureStartOrigin,
      startFocalPoint: _gestureStartFocalPoint,
      currentFocalPoint: details.localFocalPoint,
      scaleMultiplier: details.scale,
    );
    _lod.onViewportChanged(_viewportSize!, _scale, _origin);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final controller = widget.annotationController;
    if (controller != null && _isDraftingRect && controller.draft != null) {
      controller.commitRectDraft();
      return;
    }
    _lod.flushNow(_viewportSize!, _scale, _origin);
  }

  void _onTapUp(TapUpDetails details) {
    final controller = widget.annotationController;
    if (controller == null) return;
    final level0Point = _toLevel0(details.localPosition);
    switch (controller.drawMode) {
      case SvsAnnotationDrawMode.point:
        controller.commitPoint(level0Point);
      case SvsAnnotationDrawMode.polygon:
      case SvsAnnotationDrawMode.polyline:
        controller.addPathPoint(level0Point);
      case SvsAnnotationDrawMode.none:
        final hit = controller.hitTest(
          level0Point,
          widget.hitTestTolerance / _scale,
        );
        controller.select(hit?.id);
        widget.onAnnotationTap?.call(hit);
      case SvsAnnotationDrawMode.rectangle:
        break; // handled by the drag gestures above
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Scroll up (negative dy) zooms in.
    final zoomFactor = math.exp(-event.scrollDelta.dy * 0.001);
    _zoomAndPanTo(
      startScale: _scale,
      startOrigin: _origin,
      startFocalPoint: event.localPosition,
      currentFocalPoint: event.localPosition,
      scaleMultiplier: zoomFactor,
    );
    _lod.onViewportChanged(_viewportSize!, _scale, _origin);
  }

  /// Keeps the level-0 point that was under [startFocalPoint] (at
  /// [startScale]/[startOrigin]) pinned under [currentFocalPoint] at the
  /// new scale — the shared math behind pinch-zoom, wheel-zoom, and
  /// combined pan+zoom drag gestures.
  void _zoomAndPanTo({
    required double startScale,
    required Offset startOrigin,
    required Offset startFocalPoint,
    required Offset currentFocalPoint,
    required double scaleMultiplier,
  }) {
    final focalLevel0 = startOrigin + startFocalPoint / startScale;
    final newScale = (startScale * scaleMultiplier).clamp(
      _minScale,
      widget.maxScale,
    );
    final newOrigin = focalLevel0 - currentFocalPoint / newScale;
    setState(() {
      _scale = newScale;
      _origin = newOrigin;
    });
  }

  /// Recenters the viewport on [level0Point] (a coordinate in the full
  /// slide's level-0 pixel space) at the current scale — what tapping or
  /// dragging on the minimap does.
  void _navigateTo(Offset level0Point) {
    final viewportSize = _viewportSize;
    if (viewportSize == null) return;
    setState(() {
      _origin =
          level0Point -
          Offset(viewportSize.width, viewportSize.height) / (2 * _scale);
    });
    _lod.flushNow(viewportSize, _scale, _origin);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        if (_viewportSize != viewportSize) {
          _viewportSize = viewportSize;
          if (!_initialized) {
            _initialized = true;
            _initializeView(viewportSize);
          }
        }
        if (!_initialized) return const SizedBox.shrink();

        final level0 = widget.svsFile.levels.first;
        final overview = _overviewImage;

        return ClipRect(
          child: Stack(
            children: [
              Listener(
                onPointerSignal: _onPointerSignal,
                child: GestureDetector(
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
                  onScaleEnd: _onScaleEnd,
                  onTapUp: widget.annotationController == null
                      ? null
                      : _onTapUp,
                  child: CustomPaint(
                    size: viewportSize,
                    painter: _TilePainter(
                      svsFile: widget.svsFile,
                      cache: _cache,
                      scale: _scale,
                      origin: _origin,
                      maxUpsample: widget.maxUpsample,
                    ),
                  ),
                ),
              ),
              if (widget.annotationController != null)
                IgnorePointer(
                  child: AnimatedBuilder(
                    animation: widget.annotationController!,
                    builder: (context, _) => CustomPaint(
                      size: viewportSize,
                      painter: _AnnotationPainter(
                        annotations: widget.annotationController!.annotations,
                        draft: widget.annotationController!.draft,
                        selectedId: widget.annotationController!.selectedId,
                        scale: _scale,
                        origin: _origin,
                        mppX: widget.showMeasurements
                            ? widget.svsFile.metadata.mppX
                            : null,
                        mppY: widget.showMeasurements
                            ? widget.svsFile.metadata.mppY
                            : null,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 12,
                bottom: 12,
                child: _HudOverlay(
                  scale: _scale,
                  mppX: widget.svsFile.metadata.mppX,
                ),
              ),
              if (overview != null)
                Positioned(
                  right: 12,
                  top: 12,
                  child: _Minimap(
                    overviewImage: overview,
                    level0Width: level0.width,
                    level0Height: level0.height,
                    origin: _origin,
                    scale: _scale,
                    viewportSize: viewportSize,
                    onNavigate: _navigateTo,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TilePainter extends CustomPainter {
  final SvsFile svsFile;
  final TileCache cache;
  final double scale;
  final Offset origin;
  final double maxUpsample;

  _TilePainter({
    required this.svsFile,
    required this.cache,
    required this.scale,
    required this.origin,
    required this.maxUpsample,
  });

  // Anti-aliased edges on abutting tile rects each blend independently
  // against whatever was already painted, which — even when two tiles'
  // edges land on the exact same coordinate — leaves a visible hairline
  // seam of under-covered background color. Disabling AA here makes each
  // edge snap to whole device pixels instead, so neighboring tiles cover
  // each other's border pixel completely.
  static final _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = false;
  static final _placeholderPaint = Paint()
    ..color = const Color(0xFFE0E0E0)
    ..isAntiAlias = false;

  @override
  void paint(Canvas canvas, Size size) {
    // Flat fallback for any spot neither this level nor the stale-level
    // fallback below has a decoded tile for yet.
    canvas.drawRect(Offset.zero & size, _placeholderPaint);

    final levels = svsFile.levels;
    final levelIndex = selectLevel(
      levels.map((l) => l.geometry).toList(growable: false),
      scale,
      maxUpsample: maxUpsample,
    );
    final level = levels[levelIndex];

    // While `level`'s own tiles are still decoding, paint whatever
    // already-cached coarser/finer level covers this viewport underneath,
    // stretched to the current transform — a blurry preview beats a blank
    // flash during a fast zoom, and gets progressively covered by `level`'s
    // sharp tiles as they arrive.
    final fallbackIndex = _findFallbackLevelIndex(levels, levelIndex, size);
    if (fallbackIndex != null) {
      _paintLevelTiles(canvas, levels[fallbackIndex], size);
    }

    _paintLevelTiles(canvas, level, size);
  }

  void _paintLevelTiles(Canvas canvas, SvsLevel level, Size size) {
    final visible = computeVisibleTiles(level.geometry, size, scale, origin);
    for (var ty = visible.minTy; ty <= visible.maxTy; ty++) {
      for (var tx = visible.minTx; tx <= visible.maxTx; tx++) {
        final image = cache.get(
          TileCacheKey(level: level.index, tileX: tx, tileY: ty),
        );
        if (image == null) {
          continue; // background fill / fallback layer shows through
        }
        final src = Rect.fromLTWH(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        );
        canvas.drawImageRect(
          image,
          src,
          _tileScreenRect(level, tx, ty),
          _imagePaint,
        );
      }
    }
  }

  /// The already-cached level closest in index to [targetIndex] (excluding
  /// it) that has at least one visible tile decoded — checked coarser
  /// (index+1, +2, …) before finer, since "just zoomed in from a
  /// fully-loaded overview" is the common case this exists for.
  int? _findFallbackLevelIndex(
    List<SvsLevel> levels,
    int targetIndex,
    Size size,
  ) {
    for (var d = 1; d < levels.length; d++) {
      for (final candidate in [targetIndex + d, targetIndex - d]) {
        if (candidate < 0 || candidate >= levels.length) continue;
        final geometry = levels[candidate].geometry;
        final visible = computeVisibleTiles(geometry, size, scale, origin);
        for (var ty = visible.minTy; ty <= visible.maxTy; ty++) {
          for (var tx = visible.minTx; tx <= visible.maxTx; tx++) {
            if (cache.contains(
              TileCacheKey(level: candidate, tileX: tx, tileY: ty),
            )) {
              return candidate;
            }
          }
        }
      }
    }
    return null;
  }

  // Extends 1 logical pixel past each tile's true right/bottom edge. Two
  // neighboring tiles' edges *should* land on the exact same float value,
  // but floating-point associativity can drift them apart by a fraction of
  // a pixel; without this, that gap (or independent per-rect pixel
  // rounding, now that AA is off) shows through as a visible seam. The 1px
  // overlap this creates into the next tile is imperceptible.
  static const _seamGuard = 1.0;

  Rect _tileScreenRect(SvsLevel level, int tx, int ty) {
    final level0X = tx * level.tileWidth * level.downsample;
    final level0Y = ty * level.tileLength * level.downsample;
    final level0Width = level.tileWidth * level.downsample;
    final level0Height = level.tileLength * level.downsample;
    final left = (level0X - origin.dx) * scale;
    final top = (level0Y - origin.dy) * scale;
    return Rect.fromLTWH(
      left,
      top,
      level0Width * scale + _seamGuard,
      level0Height * scale + _seamGuard,
    );
  }

  @override
  bool shouldRepaint(covariant _TilePainter oldDelegate) => true;
}

/// Renders [SvsAnnotationController.annotations] (plus the in-progress
/// [SvsAnnotationController.draft], if any) over the tile layer, mapping
/// each annotation's level-0 points through the same `scale`/`origin`
/// transform [_TilePainter] uses for tiles.
class _AnnotationPainter extends CustomPainter {
  final List<SvsAnnotation> annotations;
  final SvsAnnotation? draft;
  final String? selectedId;
  final double scale;
  final Offset origin;

  /// Slide microns-per-pixel; null suppresses measurement labels entirely
  /// (either [SvsImageView.showMeasurements] is false or the slide has no
  /// microns-per-pixel metadata).
  final double? mppX;
  final double? mppY;

  _AnnotationPainter({
    required this.annotations,
    required this.draft,
    required this.selectedId,
    required this.scale,
    required this.origin,
    required this.mppX,
    required this.mppY,
  });

  static const _selectionColor = Color(0xFF2196F3);
  static const _vertexRadius = 4.0;
  static const _pointRadius = 6.0;

  Offset _toScreen(Offset level0Point) => (level0Point - origin) * scale;

  @override
  void paint(Canvas canvas, Size size) {
    for (final annotation in annotations) {
      _paintShape(canvas, annotation, selected: annotation.id == selectedId);
    }
    final draft = this.draft;
    if (draft != null) {
      _paintShape(canvas, draft, selected: false, isDraft: true);
    }
  }

  void _paintShape(
    Canvas canvas,
    SvsAnnotation annotation, {
    required bool selected,
    bool isDraft = false,
  }) {
    final baseColor = selected ? _selectionColor : annotation.color;
    final strokeColor = isDraft
        ? baseColor.withValues(alpha: 0.7)
        : baseColor;
    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected
          ? annotation.strokeWidth + 1.5
          : annotation.strokeWidth;
    final fillPaint = annotation.filled
        ? (Paint()..color = strokeColor.withValues(alpha: 0.25))
        : null;

    Offset? labelAnchor;

    switch (annotation.type) {
      case SvsAnnotationShapeType.point:
        final center = _toScreen(annotation.points.first);
        canvas.drawCircle(center, _pointRadius, Paint()..color = strokeColor);
        canvas.drawCircle(
          center,
          _pointRadius,
          Paint()
            ..color = const Color(0xFFFFFFFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      case SvsAnnotationShapeType.rectangle:
        if (annotation.points.length < 2) return;
        final rect = Rect.fromPoints(
          _toScreen(annotation.points[0]),
          _toScreen(annotation.points[1]),
        );
        if (fillPaint != null) canvas.drawRect(rect, fillPaint);
        canvas.drawRect(rect, strokePaint);
        labelAnchor = rect.center;
      case SvsAnnotationShapeType.polyline:
      case SvsAnnotationShapeType.polygon:
        if (annotation.points.isEmpty) return;
        final screenPoints = annotation.points.map(_toScreen).toList();
        final path = Path()
          ..moveTo(screenPoints.first.dx, screenPoints.first.dy);
        for (final p in screenPoints.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        if (annotation.type == SvsAnnotationShapeType.polygon) path.close();
        if (fillPaint != null &&
            annotation.type == SvsAnnotationShapeType.polygon) {
          canvas.drawPath(path, fillPaint);
        }
        canvas.drawPath(path, strokePaint);
        if (isDraft) {
          for (final p in screenPoints) {
            canvas.drawCircle(p, _vertexRadius, Paint()..color = strokeColor);
          }
        }
        labelAnchor =
            screenPoints.reduce((a, b) => a + b) / screenPoints.length.toDouble();
    }

    if (labelAnchor != null) {
      final measurement = measureAnnotation(
        annotation,
        mppX: mppX,
        mppY: mppY,
      );
      final length = measurement.lengthMicrons;
      if (length != null) {
        final area = measurement.areaMicronsSquared;
        final text = area == null
            ? formatMicrons(length)
            : '${formatMicrons(length)}  (${formatMicronsSquared(area)})';
        _drawLabel(canvas, labelAnchor, text);
      }
    }
  }

  void _drawLabel(Canvas canvas, Offset anchor, String text) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final textOrigin =
        anchor - Offset(textPainter.width / 2, textPainter.height / 2);
    final background = Paint()..color = const Color(0xB0000000);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (textOrigin & textPainter.size).inflate(3),
        const Radius.circular(3),
      ),
      background,
    );
    textPainter.paint(canvas, textOrigin);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) => true;
}

/// Bottom-left HUD: current zoom percentage (100% = one screen pixel per
/// level-0 pixel) and, when the slide's microns-per-pixel is known, a
/// physical scale bar.
class _HudOverlay extends StatelessWidget {
  final double scale;
  final double? mppX;

  const _HudOverlay({required this.scale, required this.mppX});

  @override
  Widget build(BuildContext context) {
    final zoomPercent = (scale * 100).round();
    final mpp = mppX;
    final bar = mpp == null ? null : _pickScaleBar(mpp / scale);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bar != null) ...[
              CustomPaint(
                size: Size(bar.pixelWidth, 10),
                painter: _ScaleBarPainter(),
              ),
              const SizedBox(width: 6),
              Text(
                bar.label,
                style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 12),
              ),
              const SizedBox(width: 12),
            ],
            Text(
              '$zoomPercent%',
              style: const TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScaleBarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 1.5;
    final midY = size.height / 2;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), paint);
    canvas.drawLine(Offset(0, 0), Offset(0, size.height), paint);
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScaleBarPainter oldDelegate) => false;
}

typedef _ScaleBarSpec = ({double pixelWidth, String label});

/// Picks a "nice" round physical length (1-2-5 sequence, in micrometers)
/// whose on-screen width — given [umPerScreenPixel] microns per screen
/// pixel at the current zoom — fits under [maxBarWidth], preferring the
/// largest one that still fits so the bar reads clearly.
_ScaleBarSpec? _pickScaleBar(
  double umPerScreenPixel, {
  double maxBarWidth = 120,
}) {
  if (!umPerScreenPixel.isFinite || umPerScreenPixel <= 0) return null;

  const niceValuesUm = <double>[
    0.1,
    0.2,
    0.5,
    1,
    2,
    5,
    10,
    20,
    50,
    100,
    200,
    500,
    1000,
    2000,
    5000,
    10000,
    20000,
    50000,
  ];

  var chosen = niceValuesUm.first;
  for (final value in niceValuesUm) {
    if (value / umPerScreenPixel > maxBarWidth) break;
    chosen = value;
  }

  final pixelWidth = chosen / umPerScreenPixel;
  final label = chosen >= 1000
      ? '${(chosen / 1000).toStringAsFixed(0)} mm'
      : chosen % 1 == 0
      ? '${chosen.toStringAsFixed(0)} µm'
      : '${chosen.toStringAsFixed(1)} µm';
  return (pixelWidth: pixelWidth, label: label);
}

/// Top-right minimap: the slide's thumbnail with a rectangle showing what
/// part of the full slide the main view currently shows. Tap or drag on it
/// to jump the main view there.
class _Minimap extends StatelessWidget {
  static const double _maxDimension = 160;

  final ui.Image overviewImage;
  final int level0Width;
  final int level0Height;
  final Offset origin;
  final double scale;
  final Size viewportSize;
  final ValueChanged<Offset> onNavigate;

  const _Minimap({
    required this.overviewImage,
    required this.level0Width,
    required this.level0Height,
    required this.origin,
    required this.scale,
    required this.viewportSize,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final aspect = level0Width / level0Height;
    final boxSize = aspect >= 1
        ? Size(_maxDimension, _maxDimension / aspect)
        : Size(_maxDimension * aspect, _maxDimension);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0x99FFFFFF)),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6)],
      ),
      child: GestureDetector(
        onTapUp: (details) => _navigate(details.localPosition, boxSize),
        onPanUpdate: (details) => _navigate(details.localPosition, boxSize),
        child: SizedBox(
          width: boxSize.width,
          height: boxSize.height,
          child: CustomPaint(
            painter: _MinimapPainter(
              image: overviewImage,
              level0Width: level0Width,
              level0Height: level0Height,
              origin: origin,
              scale: scale,
              viewportSize: viewportSize,
            ),
          ),
        ),
      ),
    );
  }

  void _navigate(Offset local, Size boxSize) {
    final fx = (local.dx / boxSize.width).clamp(0.0, 1.0);
    final fy = (local.dy / boxSize.height).clamp(0.0, 1.0);
    onNavigate(Offset(fx * level0Width, fy * level0Height));
  }
}

class _MinimapPainter extends CustomPainter {
  final ui.Image image;
  final int level0Width;
  final int level0Height;
  final Offset origin;
  final double scale;
  final Size viewportSize;

  _MinimapPainter({
    required this.image,
    required this.level0Width,
    required this.level0Height,
    required this.origin,
    required this.scale,
    required this.viewportSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final imageRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      imageRect,
      Paint(),
    );

    final xRatio = size.width / level0Width;
    final yRatio = size.height / level0Height;
    final viewRect = Rect.fromLTWH(
      origin.dx * xRatio,
      origin.dy * yRatio,
      (viewportSize.width / scale) * xRatio,
      (viewportSize.height / scale) * yRatio,
    ).intersect(imageRect);

    canvas.drawRect(viewRect, Paint()..color = const Color(0x40FFEB3B));
    canvas.drawRect(
      viewRect,
      Paint()
        ..color = const Color(0xFFFFEB3B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) => true;
}
