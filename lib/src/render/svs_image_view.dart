import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../cache/tile_cache.dart';
import '../svs/svs_file.dart';
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

class _SvsImageViewState extends State<SvsImageView> {
  late final TileCache _cache = widget.cache ?? TileCache();
  bool get _ownsCache => widget.cache == null;

  final Set<TileCacheKey> _inFlight = {};
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

  @override
  void dispose() {
    _debounce?.cancel();
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
    final visible = computeVisibleTiles(level.geometry, viewportSize, _scale, _origin, margin: widget.prefetchMargin);
    _wanted = visible;

    for (var ty = visible.minTy; ty <= visible.maxTy; ty++) {
      for (var tx = visible.minTx; tx <= visible.maxTx; tx++) {
        final key = TileCacheKey(level: level.index, tileX: tx, tileY: ty);
        if (_cache.contains(key) || _inFlight.contains(key)) continue;
        _inFlight.add(key);
        unawaited(_decodeTile(level, tx, ty, key));
      }
    }
  }

  bool _isStillWanted(TileCacheKey key) {
    final wanted = _wanted;
    if (wanted == null || wanted.level != key.level) return false;
    return key.tileX >= wanted.minTx && key.tileX <= wanted.maxTx && key.tileY >= wanted.minTy && key.tileY <= wanted.maxTy;
  }

  Future<void> _decodeTile(SvsLevel level, int tx, int ty, TileCacheKey key) async {
    try {
      ui.Image? image;
      if (level.isJpeg) {
        final bytes = await widget.svsFile.readTileJpegBytes(level.index, tx, ty);
        if (bytes.isNotEmpty) {
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          if (level.needsYCbCrFix) {
            final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
            frame.image.dispose();
            if (data != null) {
              final pixels = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
              undoSpuriousYCbCr(pixels);
              image = await _decodeRgba(pixels, level.tileWidth, level.tileLength);
            }
          } else {
            image = frame.image;
          }
        }
      } else {
        final rgba = await widget.svsFile.readTileRgba(level.index, tx, ty);
        if (rgba.isNotEmpty) {
          image = await _decodeRgba(rgba, level.tileWidth, level.tileLength);
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

  Future<ui.Image> _decodeRgba(Uint8List bytes, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
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

        return ClipRect(
          child: Listener(
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

  @override
  void paint(Canvas canvas, Size size) {
    final levels = svsFile.levels;
    final levelIndex = selectLevel(levels.map((l) => l.geometry).toList(growable: false), scale, maxUpsample: maxUpsample);
    final level = levels[levelIndex];
    final visible = computeVisibleTiles(level.geometry, size, scale, origin);

    // Anti-aliased edges on abutting tile rects each blend independently
    // against whatever was already painted, which — even when two tiles'
    // edges land on the exact same coordinate — leaves a visible hairline
    // seam of under-covered background color. Disabling AA here makes each
    // edge snap to whole device pixels instead, so neighboring tiles cover
    // each other's border pixel completely.
    final imagePaint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = false;
    final placeholderPaint = Paint()
      ..color = const Color(0xFFE0E0E0)
      ..isAntiAlias = false;

    for (var ty = visible.minTy; ty <= visible.maxTy; ty++) {
      for (var tx = visible.minTx; tx <= visible.maxTx; tx++) {
        final dst = _tileScreenRect(level, tx, ty);
        final image = cache.get(TileCacheKey(level: level.index, tileX: tx, tileY: ty));
        if (image != null) {
          final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
          canvas.drawImageRect(image, src, dst, imagePaint);
        } else {
          canvas.drawRect(dst, placeholderPaint);
        }
      }
    }
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
