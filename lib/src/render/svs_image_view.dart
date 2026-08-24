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
import 'image_adjustments.dart';
import 'lod_controller.dart';
import 'viewport_math.dart';

/// How [SvsImageView] fits the level-0 image to the viewport when its
/// aspect ratio doesn't match the slide's.
enum SvsImageFit {
  /// Scales down until the whole image fits inside the viewport, matching
  /// its own aspect ratio — the mismatched dimension is left as bars of
  /// [SvsImageView.backgroundColor] rather than cropping any of the slide.
  contain,

  /// Scales up until the image fills the viewport completely, cropping
  /// whichever dimension overflows — no background ever shows at the
  /// minimum zoom, at the cost of not showing the full slide at once.
  cover,
}

/// A pannable, zoomable view of an open [SvsFile]'s resolution pyramid.
///
/// Streams only the tiles needed for the current viewport/zoom level,
/// decoding on demand and caching decoded tiles in [cache] (an internally
/// owned [TileCache] if none is supplied — pass a shared one to reuse
/// decoded tiles across multiple [SvsImageView]s of the same file).
///
/// Does not take ownership of [svsFile]: the caller opened it and must
/// close it, typically after this widget is disposed.
///
/// The initial view fits the level-0 image to the viewport per [fit]. With
/// the default [SvsImageFit.contain], a viewport whose aspect ratio doesn't
/// match the slide's leaves bars of [backgroundColor] on two sides (like
/// letterboxing a video) — that's expected, not a rendering bug, and the
/// same bars are also what shows through any spot whose tile hasn't decoded
/// yet. Pick [SvsImageFit.cover] instead to fill the viewport completely,
/// cropping the slide's edges at the initial (minimum) zoom.
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

  /// Brightness/contrast/shadow/highlight adjustment applied to every
  /// rendered tile. Left at [SvsImageAdjustments.none] (the default), tiles
  /// render unmodified. Cheap to change on every frame (e.g. from a slider)
  /// — it's a GPU color filter, not a per-tile re-decode.
  final SvsImageAdjustments adjustments;

  /// Whether the top-right minimap (thumbnail + viewport rectangle) shows.
  /// When false, the slide's thumbnail is never even decoded — not just
  /// hidden — since nothing else in this widget needs it.
  final bool showMinimap;

  /// Whether the bottom-left HUD shows the current zoom percentage.
  final bool showZoomLevel;

  /// Whether the bottom-left HUD shows the physical (µm/mm) scale bar. No
  /// effect if the slide has no microns-per-pixel metadata — there's never
  /// a bar to show either way in that case.
  final bool showScaleBar;

  /// How the level-0 image is fit to the viewport on open (and at the
  /// minimum zoom thereafter). See the class doc comment for what each
  /// value does to the viewport's aspect-ratio mismatch, if any.
  final SvsImageFit fit;

  /// Fill color for any part of the viewport not currently covered by a
  /// decoded tile — both the letterbox/pillarbox bars [fit] can leave
  /// outside the slide's bounds, and any in-bounds spot whose tile hasn't
  /// decoded yet. Defaults to a neutral light gray; set it to match the
  /// surrounding UI (e.g. the enclosing `Scaffold`'s background) so empty
  /// space reads as "nothing here yet" rather than as slide content.
  final Color backgroundColor;

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
    this.adjustments = SvsImageAdjustments.none,
    this.showMinimap = true,
    this.showZoomLevel = true,
    this.showScaleBar = true,
    this.fit = SvsImageFit.contain,
    this.backgroundColor = const Color(0xFFE0E0E0),
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

  // Raw-pointer tap tracking — see _onPointerDown's doc comment for why tap
  // detection is done this way instead of GestureDetector's onTapUp.
  final Set<int> _activePointers = {};
  int? _tapCandidatePointer;
  Offset _tapCandidateStart = Offset.zero;
  bool _tapCandidateMoved = false;
  bool _tapCandidateMultiTouch = false;

  ui.Image? _overviewImage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lod.addListener(_onTilesChanged);
    // So the gesture layer's pan/zoom suppression (see
    // _isDrawingAnnotation) picks up a `drawMode` change on the very next
    // gesture, not just whatever later rebuild happens to come along for an
    // unrelated reason.
    widget.annotationController?.addListener(_onAnnotationChanged);
    if (widget.showMinimap) unawaited(_loadOverview());
  }

  void _onTilesChanged() {
    if (mounted) setState(() {});
  }

  void _onAnnotationChanged() {
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
    widget.annotationController?.removeListener(_onAnnotationChanged);
    _lod.dispose();
    _overviewImage?.dispose();
    if (_ownsCache) _cache.clear();
    super.dispose();
  }

  void _initializeView(Size viewportSize) {
    final level0 = widget.svsFile.levels.first;
    final scaleToFitWidth = viewportSize.width / level0.width;
    final scaleToFitHeight = viewportSize.height / level0.height;
    final fitScale = widget.fit == SvsImageFit.cover
        ? math.max(scaleToFitWidth, scaleToFitHeight)
        : math.min(scaleToFitWidth, scaleToFitHeight);
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

  /// The tile layer plus its pointer handling — pan/zoom via
  /// [_onScaleStart]/[_onScaleUpdate]/[_onScaleEnd] (nulled out entirely
  /// while [_isDrawingAnnotation] and not [_isDraftingRect] — see that
  /// getter's doc comment) and tap detection via raw pointer events (see
  /// [_onPointerDown]'s doc comment for why, not `GestureDetector`'s own
  /// `onTapUp`). Re-evaluated on every build, including ones triggered by
  /// [_onAnnotationChanged] when the annotation controller's `drawMode`
  /// changes.
  Widget _buildGestureLayer(Size viewportSize) {
    final suppressPanZoom = _isDrawingAnnotation && !_isDraftingRect;
    return Listener(
      onPointerSignal: _onPointerSignal,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        onScaleStart: suppressPanZoom ? null : _onScaleStart,
        onScaleUpdate: suppressPanZoom ? null : _onScaleUpdate,
        onScaleEnd: suppressPanZoom ? null : _onScaleEnd,
        child: CustomPaint(
          size: viewportSize,
          painter: _TilePainter(
            svsFile: widget.svsFile,
            cache: _cache,
            scale: _scale,
            origin: _origin,
            maxUpsample: widget.maxUpsample,
            adjustments: widget.adjustments,
            backgroundColor: widget.backgroundColor,
          ),
        ),
      ),
    );
  }

  bool get _isDraftingRect =>
      widget.annotationController?.drawMode == SvsAnnotationDrawMode.rectangle;

  /// Whether an annotation shape is actively being drawn — while true,
  /// pan/zoom must stay fully inert. Rectangle mode already gets its own
  /// dedicated drag handling below ([_isDraftingRect]); point/polyline/
  /// polygon mode instead places vertices via [_handleTap], one tap at a
  /// time — but the same [GestureDetector] would otherwise still run a
  /// `ScaleGestureRecognizer` underneath every tap (`onScaleStart`/
  /// `onScaleUpdate` fire on pointer down/move regardless of draw mode). A
  /// quick series of taps placing several vertices could have its
  /// pointer-down/up events overlap enough for the recognizer to briefly see
  /// two "concurrent" pointers and compute a wild span-ratio scale from
  /// them — visible as the zoom-percent HUD jumping to a nonsensical number.
  /// [_buildGestureLayer] nulls out `onScaleStart`/`onScaleUpdate`/
  /// `onScaleEnd` on the `GestureDetector` outright when this is true
  /// (`GestureDetector` treats a null callback as "don't recognize this
  /// gesture at all") — the recognizer never starts tracking pointers in the
  /// first place, rather than starting and having its result discarded.
  bool get _isDrawingAnnotation =>
      widget.annotationController != null &&
      widget.annotationController!.drawMode != SvsAnnotationDrawMode.none;

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

  /// Routes a tap at [localPosition] (screen coordinates) the same way
  /// [SvsAnnotationDrawMode] dictates for every other pointer interaction —
  /// called from [_onPointerUp] once it's decided the just-finished gesture
  /// really was a tap.
  void _handleTap(Offset localPosition) {
    final controller = widget.annotationController;
    if (controller == null) return;
    final level0Point = _toLevel0(localPosition);
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

  /// Tap detection via raw pointer events instead of `GestureDetector`'s own
  /// `onTapUp`/`TapGestureRecognizer` — deliberately. `TapGestureRecognizer`
  /// and `ScaleGestureRecognizer` would otherwise both be live for the same
  /// pointer in `drawMode.none` (pan/zoom stays active there, and a tap
  /// should still select an annotation), and having them compete in the
  /// same gesture arena makes `ScaleGestureRecognizer`'s own scale-ratio
  /// math for a genuine two-finger pinch unreliable — confirmed empirically:
  /// removing the competing tap recognizer alone fixed a pinch that
  /// otherwise sometimes computed `scale == 1.0` (no zoom at all) even
  /// though a second pointer clearly moved. `Listener`'s raw pointer
  /// callbacks don't participate in the gesture arena at all — they fire
  /// unconditionally alongside whatever `GestureDetector`'s own recognizers
  /// decide — so tracking taps here sidesteps the competition entirely,
  /// this widget's pan/zoom gestures included.
  void _onPointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (_activePointers.length == 1) {
      _tapCandidatePointer = event.pointer;
      _tapCandidateStart = event.localPosition;
      _tapCandidateMoved = false;
      _tapCandidateMultiTouch = false;
    } else {
      // A second (or later) pointer joined mid-gesture — definitely not a
      // tap anymore (a pinch, most likely).
      _tapCandidateMultiTouch = true;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer == _tapCandidatePointer &&
        (event.localPosition - _tapCandidateStart).distance > kTouchSlop) {
      _tapCandidateMoved = true;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    // Only counts as a tap if: it's the same pointer the candidate started
    // with, it never moved past the slop, no other pointer ever joined, and
    // this was the very last pointer to lift (so a two-finger gesture
    // doesn't get treated as a tap just because one finger happened to lift
    // without moving).
    if (event.pointer == _tapCandidatePointer &&
        !_tapCandidateMoved &&
        !_tapCandidateMultiTouch &&
        _activePointers.isEmpty) {
      _handleTap(event.localPosition);
    }
    if (_activePointers.isEmpty) _tapCandidatePointer = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) _tapCandidatePointer = null;
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
              // _onAnnotationChanged (registered in initState) already
              // triggers a rebuild whenever `drawMode` changes, so this
              // always reflects the current pan/zoom suppression state
              // (see _isDrawingAnnotation) without needing an AnimatedBuilder
              // wrapped around it.
              _buildGestureLayer(viewportSize),
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
              if (widget.showZoomLevel || widget.showScaleBar)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _HudOverlay(
                    scale: _scale,
                    minScale: _minScale,
                    mppX: widget.svsFile.metadata.mppX,
                    appMag: widget.svsFile.metadata.appMag,
                    showZoomLevel: widget.showZoomLevel,
                    showScaleBar: widget.showScaleBar,
                  ),
                ),
              if (overview != null && widget.showMinimap)
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
  final SvsImageAdjustments adjustments;
  final Color backgroundColor;

  _TilePainter({
    required this.svsFile,
    required this.cache,
    required this.scale,
    required this.origin,
    required this.maxUpsample,
    required this.adjustments,
    required this.backgroundColor,
  });

  // Anti-aliased edges on abutting tile rects each blend independently
  // against whatever was already painted, which — even when two tiles'
  // edges land on the exact same coordinate — leaves a visible hairline
  // seam of under-covered background color. Disabling AA here makes each
  // edge snap to whole device pixels instead, so neighboring tiles cover
  // each other's border pixel completely.
  //
  // Not `static`/shared: `colorFilter` varies per [adjustments], and
  // different `SvsImageView`s can have different adjustments at once.
  late final _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = false
    ..colorFilter = adjustments.toColorFilter();

  // Not `static`/shared: `color` varies per [backgroundColor], and different
  // `SvsImageView`s can have different background colors at once.
  late final _placeholderPaint = Paint()
    ..color = backgroundColor
    ..isAntiAlias = false;

  @override
  void paint(Canvas canvas, Size size) {
    // Flat fallback for any spot neither this level nor the stale-level
    // fallback below has a decoded tile for yet — including, permanently,
    // any letterbox/pillarbox bars outside the slide's own bounds when
    // `fit` is `SvsImageFit.contain` (those spots never get a tile at all,
    // since they fall outside every level's geometry).
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

  /// [level]'s full extent, converted to screen space — a right/bottom-edge
  /// tile's *decoded* image is sometimes padded up to the nominal tile size
  /// by the encoder (JPEG requires whole 8x8/16x16 blocks), typically with
  /// edge-replicated pixels rather than blank ones. [_tileScreenRect] now
  /// sizes every tile's `dst` rect from that tile's own decoded dimensions,
  /// so an unpadded boundary tile (decoded smaller than nominal) is no
  /// longer stretched to fill nominal-sized space — but a *padded* one still
  /// paints its extra rows/columns past the level's true bottom/right edge.
  /// Clipping every tile draw to this rect keeps that padding from ever
  /// becoming visible.
  Rect _levelExtentScreenRect(SvsLevel level) => Rect.fromLTWH(
    -origin.dx * scale,
    -origin.dy * scale,
    level.width * level.downsample * scale,
    level.height * level.downsample * scale,
  );

  void _paintLevelTiles(Canvas canvas, SvsLevel level, Size size) {
    final visible = computeVisibleTiles(level.geometry, size, scale, origin);
    canvas.save();
    canvas.clipRect(_levelExtentScreenRect(level));
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
          _tileScreenRect(level, tx, ty, image),
          _imagePaint,
        );
      }
    }
    canvas.restore();
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

  Rect _tileScreenRect(SvsLevel level, int tx, int ty, ui.Image image) {
    final level0X = tx * level.tileWidth * level.downsample;
    final level0Y = ty * level.tileLength * level.downsample;
    // Sized from the tile's own decoded dimensions, not the nominal tile
    // grid size — those only match when this tile isn't a right/bottom-edge
    // one, or the encoder padded it up to full size. An edge tile decoded
    // *smaller* than nominal (legal per the TIFF new-style-JPEG scheme) must
    // keep its dst rect that same smaller size, or drawImageRect stretches
    // its real content to fill the extra space non-uniformly.
    final level0Width = image.width * level.downsample;
    final level0Height = image.height * level.downsample;
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
    final strokeColor = isDraft ? baseColor.withValues(alpha: 0.7) : baseColor;
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
            screenPoints.reduce((a, b) => a + b) /
            screenPoints.length.toDouble();
    }

    if (labelAnchor != null) {
      final measurement = measureAnnotation(annotation, mppX: mppX, mppY: mppY);
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
/// level-0 pixel), how much of the *whole* slide the viewport currently
/// covers (100% at the initial/minimum zoom, shrinking as the view zooms
/// in), the equivalent objective magnification (when the slide's scan
/// magnification is known), and, when the slide's microns-per-pixel is
/// known, a physical scale bar — the zoom/coverage/magnification group and
/// the scale bar independently toggleable via [showZoomLevel]/
/// [showScaleBar]. Only built at all when at least one of them is true (see
/// the caller in [_SvsImageViewState.build]).
class _HudOverlay extends StatelessWidget {
  final double scale;
  final double minScale;
  final double? mppX;
  final int? appMag;
  final bool showZoomLevel;
  final bool showScaleBar;

  const _HudOverlay({
    required this.scale,
    required this.minScale,
    required this.mppX,
    required this.appMag,
    required this.showZoomLevel,
    required this.showScaleBar,
  });

  @override
  Widget build(BuildContext context) {
    final zoomPercent = (scale * 100).round();
    final coveragePercent = (minScale / scale * 100).round();
    final mag = appMag;
    final magnification = mag != null ? mag * scale : null;
    final mpp = mppX;
    final bar = (showScaleBar && mpp != null)
        ? _pickScaleBar(mpp / scale)
        : null;

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
              if (showZoomLevel) const SizedBox(width: 12),
            ],
            if (showZoomLevel) ...[
              _HudChip(glyph: '%', label: '$zoomPercent%'),
              const SizedBox(width: 10),
              _HudChip(glyph: 'V', label: '$coveragePercent%'),
              if (magnification != null) ...[
                const SizedBox(width: 10),
                _HudChip(
                  glyph: '×',
                  label: '${_formatMagnification(magnification)}x',
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// One label+glyph in [_HudOverlay]. [glyph] (a single character, e.g. "%"
/// or "×") is drawn in a bordered box rather than via `Icon`/`IconData` —
/// this package has no `material.dart` dependency (see this file's imports)
/// to pull the `Icons` constant set from.
class _HudChip extends StatelessWidget {
  final String glyph;
  final String label;

  const _HudChip({required this.glyph, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFFFFFFF), width: 1),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            glyph,
            style: const TextStyle(
              color: Color(0xFFFFFFFF),
              fontSize: 9,
              fontWeight: FontWeight.bold,
              height: 1,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

/// Formats an equivalent-magnification value for the HUD chip: two decimal
/// places under 10x (where the difference between e.g. 0.17x and 0.2x
/// matters), whole numbers at or above it (matching how objective
/// magnifications are conventionally written, e.g. "20x" not "20.00x").
String _formatMagnification(double value) {
  return value < 10 ? value.toStringAsFixed(2) : value.toStringAsFixed(0);
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
