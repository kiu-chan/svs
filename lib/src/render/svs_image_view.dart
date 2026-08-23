import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../cache/tile_cache.dart';
import '../io/tile_worker_pool.dart';
import '../svs/svs_file.dart';
import 'associated_image_decoder.dart';
import 'viewport_math.dart';
import 'ycbcr_fix.dart';

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

  /// How far a level's stored texels may be upsampled on screen before the
  /// next-finer level is chosen instead. See [selectLevel].
  final double maxUpsample;

  /// Screen pixels per level-0 pixel a user may zoom in to.
  final double maxScale;

  /// Extra tiles fetched beyond the visible range on every side, so panning
  /// a short distance doesn't show blank tiles while they decode.
  final int prefetchMargin;

  const SvsImageView({
    super.key,
    required this.svsFile,
    this.cache,
    this.maxUpsample = 1.3,
    this.maxScale = 4.0,
    this.prefetchMargin = 1,
  });

  @override
  State<SvsImageView> createState() => _SvsImageViewState();
}

class _SvsImageViewState extends State<SvsImageView> with WidgetsBindingObserver {
  late final TileCache _cache = widget.cache ?? TileCache();
  bool get _ownsCache => widget.cache == null;

  // Value is the TileWorkerPool requestId once known, so a tile that
  // scrolls out of range can be actively cancelled instead of just having
  // its eventual result ignored. Null until the pool (awaited
  // asynchronously) actually issues the request; requests fetched via the
  // main-isolate fallback path never get one and can't be cancelled early.
  final Map<TileCacheKey, int?> _inFlight = {};
  VisibleTiles? _wanted;
  Timer? _debounce;

  Size? _viewportSize;
  bool _initialized = false;
  double _scale = 1;
  double _minScale = 1;
  Offset _origin = Offset.zero;

  double _gestureStartScale = 1;
  Offset _gestureStartOrigin = Offset.zero;
  Offset _gestureStartFocalPoint = Offset.zero;

  ui.Image? _overviewImage;

  /// Tile bytes are fetched (and, for JPEG2000, decoded) on background
  /// isolates so slow disk/network I/O and the JP2K wavelet decode don't
  /// block the UI thread. If spawning the pool itself fails, [_fetchTileBytes]
  /// falls back to fetching directly on the main isolate instead of bricking
  /// the whole view.
  late final Future<TileWorkerPool> _poolFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poolFuture = TileWorkerPool.spawn(widget.svsFile.path);
    unawaited(_loadOverview());
  }

  /// The OS is telling every app to free memory it doesn't strictly need
  /// right now — decoded tiles are exactly that (cheaply re-fetched later),
  /// so drop them all rather than risk being killed for a cache that's just
  /// a speed optimization.
  @override
  void didHaveMemoryPressure() {
    _cache.clear();
    if (!mounted) return;
    setState(() {}); // the tiles just disposed were still on screen — repaint placeholders instead of a stale-image crash
    _scheduleTileRefresh(immediate: true); // re-fetch what's currently visible
  }

  Future<void> _loadOverview() async {
    SvsAssociatedImage? thumbnail;
    for (final associated in widget.svsFile.associatedImages) {
      if (associated.kind == AssociatedImageKind.thumbnail && associated.isDecodable) {
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
    _debounce?.cancel();
    _overviewImage?.dispose();
    unawaited(_poolFuture.then((pool) => pool.dispose(), onError: (_) {}));
    if (_ownsCache) _cache.clear();
    super.dispose();
  }

  void _initializeView(Size viewportSize) {
    final level0 = widget.svsFile.levels.first;
    final fitScale = math.min(viewportSize.width / level0.width, viewportSize.height / level0.height);
    _minScale = fitScale;
    _scale = fitScale;
    final contentWidth = viewportSize.width / _scale;
    final contentHeight = viewportSize.height / _scale;
    _origin = Offset((level0.width - contentWidth) / 2, (level0.height - contentHeight) / 2);
    _scheduleTileRefresh(immediate: true);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartScale = _scale;
    _gestureStartOrigin = _origin;
    _gestureStartFocalPoint = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    _zoomAndPanTo(
      startScale: _gestureStartScale,
      startOrigin: _gestureStartOrigin,
      startFocalPoint: _gestureStartFocalPoint,
      currentFocalPoint: details.localFocalPoint,
      scaleMultiplier: details.scale,
    );
    _scheduleTileRefresh();
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _scheduleTileRefresh(immediate: true);
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
    _scheduleTileRefresh();
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
    final newScale = (startScale * scaleMultiplier).clamp(_minScale, widget.maxScale);
    final newOrigin = focalLevel0 - currentFocalPoint / newScale;
    setState(() {
      _scale = newScale;
      _origin = newOrigin;
    });
  }

  void _scheduleTileRefresh({bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      _refreshTiles();
    } else {
      _debounce = Timer(const Duration(milliseconds: 80), _refreshTiles);
    }
  }

  void _refreshTiles() {
    final viewportSize = _viewportSize;
    if (viewportSize == null) return;

    final levels = widget.svsFile.levels;
    final levelIndex = selectLevel(
      levels.map((l) => l.geometry).toList(growable: false),
      _scale,
      maxUpsample: widget.maxUpsample,
    );
    final level = levels[levelIndex];
    // The strictly-on-screen range vs. the range expanded by the prefetch
    // margin — on-screen tiles are routed to the "visible" worker so they
    // never queue behind prefetch-margin ones (see TileWorkerPool).
    final core = computeVisibleTiles(level.geometry, viewportSize, _scale, _origin);
    final expanded = computeVisibleTiles(level.geometry, viewportSize, _scale, _origin, margin: widget.prefetchMargin);
    _wanted = expanded;

    final wantedKeys = <TileCacheKey>{
      for (var ty = expanded.minTy; ty <= expanded.maxTy; ty++)
        for (var tx = expanded.minTx; tx <= expanded.maxTx; tx++) TileCacheKey(level: level.index, tileX: tx, tileY: ty),
    };

    // Anything still in flight for a tile we no longer want (scrolled out
    // of range, or the target level changed) gets actively cancelled —
    // otherwise it'd keep occupying a worker and consuming bandwidth for a
    // result nobody will use.
    final toCancel = _inFlight.entries.where((entry) => !wantedKeys.contains(entry.key)).toList();
    for (final entry in toCancel) {
      _inFlight.remove(entry.key);
      final requestId = entry.value;
      if (requestId != null) {
        unawaited(_poolFuture.then((pool) => pool.cancel(requestId), onError: (_) {}));
      }
    }

    for (var ty = expanded.minTy; ty <= expanded.maxTy; ty++) {
      for (var tx = expanded.minTx; tx <= expanded.maxTx; tx++) {
        final key = TileCacheKey(level: level.index, tileX: tx, tileY: ty);
        if (_cache.contains(key) || _inFlight.containsKey(key)) continue;
        _inFlight[key] = null;
        final isCore = tx >= core.minTx && tx <= core.maxTx && ty >= core.minTy && ty <= core.maxTy;
        unawaited(_decodeTile(level, tx, ty, key, isCore ? TilePriority.visible : TilePriority.prefetch));
      }
    }
  }

  bool _isStillWanted(TileCacheKey key) {
    final wanted = _wanted;
    if (wanted == null || wanted.level != key.level) return false;
    return key.tileX >= wanted.minTx && key.tileX <= wanted.maxTx && key.tileY >= wanted.minTy && key.tileY <= wanted.maxTy;
  }

  Future<void> _decodeTile(SvsLevel level, int tx, int ty, TileCacheKey key, TilePriority priority) async {
    try {
      final result = await _fetchTileBytes(level, tx, ty, key, priority);
      final bytes = result.bytes;
      ui.Image? image;
      if (bytes != null) {
        if (result.isRgba) {
          // JPEG2000: already decoded to RGBA by the worker (via
          // openjpeg_ffi, which has no main-isolate restriction). Aperio's
          // JP2K tiles are always encoded at the full nominal tile-grid
          // size (unlike JPEG, a boundary tile can't come back cropped),
          // so `level.tileWidth/tileLength` is the correct buffer shape.
          image = await _decodeRgba(bytes, level.tileWidth, level.tileLength);
        } else {
          // JPEG: the worker only spliced the standalone bytes — the actual
          // decode must happen here, `dart:ui`'s codec APIs only work on
          // the main isolate (flutter/flutter#109701).
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          if (level.needsYCbCrFix) {
            final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
            // A tile at the right/bottom edge of the level can legally
            // decode smaller than the nominal tile size — use the frame's
            // *actual* dimensions here, not level.tileWidth/tileLength, or
            // decodeImageFromPixels gets fed a buffer of the wrong length.
            final actualWidth = frame.image.width;
            final actualHeight = frame.image.height;
            frame.image.dispose();
            if (data != null) {
              final pixels = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
              undoSpuriousYCbCr(pixels);
              image = await _decodeRgba(pixels, actualWidth, actualHeight);
            }
          } else {
            image = frame.image;
          }
        }
      }

      _inFlight.remove(key);
      if (image == null) return;
      if (!mounted) {
        image.dispose();
        return;
      }
      _cache.put(key, image, image.width * image.height * 4);
      if (_isStillWanted(key) && mounted) setState(() {});
    } catch (_) {
      _inFlight.remove(key);
      // Leave this tile blank rather than letting one bad tile crash the view.
    }
  }

  /// Routes through the isolate pool; if the pool itself never became
  /// available (spawn failed), falls back to fetching directly on the main
  /// isolate rather than leaving every tile permanently blank. Records the
  /// pool request's id into [_inFlight] as soon as it's known, so
  /// [_refreshTiles] can actively [TileWorkerPool.cancel] it later.
  Future<TileWorkerResult> _fetchTileBytes(SvsLevel level, int tx, int ty, TileCacheKey key, TilePriority priority) async {
    TileWorkerPool? pool;
    try {
      pool = await _poolFuture;
    } catch (_) {
      pool = null;
    }
    if (pool != null) {
      final handle = pool.requestTile(level: level.index, tileX: tx, tileY: ty, priority: priority);
      _inFlight[key] = handle.requestId;
      return handle.result;
    }
    if (level.isJpeg) {
      final bytes = await widget.svsFile.readTileJpegBytes(level.index, tx, ty);
      return TileWorkerResult(bytes: bytes.isEmpty ? null : bytes, isRgba: false);
    }
    final rgba = await widget.svsFile.readTileRgba(level.index, tx, ty);
    return TileWorkerResult(bytes: rgba.isEmpty ? null : rgba, isRgba: true);
  }

  Future<ui.Image> _decodeRgba(Uint8List bytes, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  /// Recenters the viewport on [level0Point] (a coordinate in the full
  /// slide's level-0 pixel space) at the current scale — what tapping or
  /// dragging on the minimap does.
  void _navigateTo(Offset level0Point) {
    final viewportSize = _viewportSize;
    if (viewportSize == null) return;
    setState(() {
      _origin = level0Point - Offset(viewportSize.width, viewportSize.height) / (2 * _scale);
    });
    _scheduleTileRefresh(immediate: true);
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
                  child: CustomPaint(
                    size: viewportSize,
                    painter: _TilePainter(svsFile: widget.svsFile, cache: _cache, scale: _scale, origin: _origin, maxUpsample: widget.maxUpsample),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                bottom: 12,
                child: _HudOverlay(scale: _scale, mppX: widget.svsFile.metadata.mppX),
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

  _TilePainter({required this.svsFile, required this.cache, required this.scale, required this.origin, required this.maxUpsample});

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
    final levelIndex = selectLevel(levels.map((l) => l.geometry).toList(growable: false), scale, maxUpsample: maxUpsample);
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
        final image = cache.get(TileCacheKey(level: level.index, tileX: tx, tileY: ty));
        if (image == null) continue; // background fill / fallback layer shows through
        final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
        canvas.drawImageRect(image, src, _tileScreenRect(level, tx, ty), _imagePaint);
      }
    }
  }

  /// The already-cached level closest in index to [targetIndex] (excluding
  /// it) that has at least one visible tile decoded — checked coarser
  /// (index+1, +2, …) before finer, since "just zoomed in from a
  /// fully-loaded overview" is the common case this exists for.
  int? _findFallbackLevelIndex(List<SvsLevel> levels, int targetIndex, Size size) {
    for (var d = 1; d < levels.length; d++) {
      for (final candidate in [targetIndex + d, targetIndex - d]) {
        if (candidate < 0 || candidate >= levels.length) continue;
        final geometry = levels[candidate].geometry;
        final visible = computeVisibleTiles(geometry, size, scale, origin);
        for (var ty = visible.minTy; ty <= visible.maxTy; ty++) {
          for (var tx = visible.minTx; tx <= visible.maxTx; tx++) {
            if (cache.contains(TileCacheKey(level: candidate, tileX: tx, tileY: ty))) {
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
    return Rect.fromLTWH(left, top, level0Width * scale + _seamGuard, level0Height * scale + _seamGuard);
  }

  @override
  bool shouldRepaint(covariant _TilePainter oldDelegate) => true;
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
      decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(6)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bar != null) ...[
              CustomPaint(size: Size(bar.pixelWidth, 10), painter: _ScaleBarPainter()),
              const SizedBox(width: 6),
              Text(bar.label, style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 12)),
              const SizedBox(width: 12),
            ],
            Text('$zoomPercent%', style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 12, fontWeight: FontWeight.bold)),
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
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _ScaleBarPainter oldDelegate) => false;
}

typedef _ScaleBarSpec = ({double pixelWidth, String label});

/// Picks a "nice" round physical length (1-2-5 sequence, in micrometers)
/// whose on-screen width — given [umPerScreenPixel] microns per screen
/// pixel at the current zoom — fits under [maxBarWidth], preferring the
/// largest one that still fits so the bar reads clearly.
_ScaleBarSpec? _pickScaleBar(double umPerScreenPixel, {double maxBarWidth = 120}) {
  if (!umPerScreenPixel.isFinite || umPerScreenPixel <= 0) return null;

  const niceValuesUm = <double>[0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000];

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
    final boxSize = aspect >= 1 ? Size(_maxDimension, _maxDimension / aspect) : Size(_maxDimension * aspect, _maxDimension);

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
    canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), imageRect, Paint());

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
