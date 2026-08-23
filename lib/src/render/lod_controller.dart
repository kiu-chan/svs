import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Size;

import '../cache/tile_cache.dart';
import '../io/tile_worker_pool.dart';
import '../svs/svs_file.dart';
import 'viewport_math.dart';
import 'ycbcr_fix.dart';

/// Decides which tiles a given viewport needs, fetches/decodes them (off the
/// main isolate where possible — see [TileWorkerPool]), writes decoded tiles
/// into [cache], and cancels requests that fall out of range before they
/// finish. Calls [notifyListeners] whenever a newly decoded tile lands in
/// [cache] and is still wanted, so a listener can trigger a repaint.
///
/// Pure orchestration: no gesture handling, no painting, no knowledge of
/// [SvsImageView] — deliberately separated out so it's testable against a
/// real [SvsFile] without spinning up a widget tree.
class LodController extends ChangeNotifier {
  final SvsFile svsFile;
  final TileCache cache;

  /// How far a level's stored texels may be upsampled on screen before the
  /// next-finer level is chosen instead. See [selectLevel].
  final double maxUpsample;

  /// Extra tiles fetched beyond the visible range on every side, so panning
  /// a short distance doesn't show blank tiles while they decode.
  final int prefetchMargin;

  /// Tile bytes are fetched (and, for JPEG2000, decoded) on background
  /// isolates so slow disk/network I/O and the JP2K wavelet decode don't
  /// block the UI thread. If spawning the pool itself fails, tile fetches
  /// fall back to running directly on the main isolate instead of bricking
  /// the whole view. Overridable so tests can inject an already-spawned
  /// pool instead of paying isolate-spawn cost per test.
  final Future<TileWorkerPool> poolFuture;

  LodController({
    required this.svsFile,
    required this.cache,
    this.maxUpsample = 1.3,
    this.prefetchMargin = 1,
    Future<TileWorkerPool>? pool,
  }) : poolFuture = pool ?? TileWorkerPool.spawn(svsFile.path);

  // Value is the TileWorkerPool requestId once known, so a tile that
  // scrolls out of range can be actively cancelled instead of just having
  // its eventual result ignored. Null until the pool (awaited
  // asynchronously) actually issues the request; requests fetched via the
  // main-isolate fallback path never get one and can't be cancelled early.
  final Map<TileCacheKey, int?> _inFlight = {};
  VisibleTiles? _wanted;
  Timer? _debounce;
  bool _disposed = false;

  /// Debounced viewport-change entry point — call on every gesture update
  /// (drag/pinch/scroll) so a fast-moving gesture doesn't spam isolate
  /// messages every frame.
  void onViewportChanged(Size viewportSize, double scale, Offset origin) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 80),
      () => _refreshTiles(viewportSize, scale, origin),
    );
  }

  /// Same as [onViewportChanged] but skips the debounce — call at
  /// gesture-end, first layout, or after a jump navigation (e.g. a minimap
  /// tap), so that result is fetched right away instead of waiting out the
  /// debounce window.
  void flushNow(Size viewportSize, double scale, Offset origin) {
    _debounce?.cancel();
    _refreshTiles(viewportSize, scale, origin);
  }

  void _refreshTiles(Size viewportSize, double scale, Offset origin) {
    final levels = svsFile.levels;
    final levelIndex = selectLevel(
      levels.map((l) => l.geometry).toList(growable: false),
      scale,
      maxUpsample: maxUpsample,
    );
    final level = levels[levelIndex];
    // The strictly-on-screen range vs. the range expanded by the prefetch
    // margin — on-screen tiles are routed to the "visible" worker so they
    // never queue behind prefetch-margin ones (see TileWorkerPool).
    final core = computeVisibleTiles(
      level.geometry,
      viewportSize,
      scale,
      origin,
    );
    final expanded = computeVisibleTiles(
      level.geometry,
      viewportSize,
      scale,
      origin,
      margin: prefetchMargin,
    );
    _wanted = expanded;

    final wantedKeys = <TileCacheKey>{
      for (var ty = expanded.minTy; ty <= expanded.maxTy; ty++)
        for (var tx = expanded.minTx; tx <= expanded.maxTx; tx++)
          TileCacheKey(level: level.index, tileX: tx, tileY: ty),
    };

    // Anything still in flight for a tile we no longer want (scrolled out
    // of range, or the target level changed) gets actively cancelled —
    // otherwise it'd keep occupying a worker and consuming bandwidth for a
    // result nobody will use.
    final toCancel = _inFlight.entries
        .where((entry) => !wantedKeys.contains(entry.key))
        .toList();
    for (final entry in toCancel) {
      _inFlight.remove(entry.key);
      final requestId = entry.value;
      if (requestId != null) {
        unawaited(
          poolFuture.then((pool) => pool.cancel(requestId), onError: (_) {}),
        );
      }
    }

    for (var ty = expanded.minTy; ty <= expanded.maxTy; ty++) {
      for (var tx = expanded.minTx; tx <= expanded.maxTx; tx++) {
        final key = TileCacheKey(level: level.index, tileX: tx, tileY: ty);
        if (cache.contains(key) || _inFlight.containsKey(key)) continue;
        _inFlight[key] = null;
        final isCore =
            tx >= core.minTx &&
            tx <= core.maxTx &&
            ty >= core.minTy &&
            ty <= core.maxTy;
        unawaited(
          _decodeTile(
            level,
            tx,
            ty,
            key,
            isCore ? TilePriority.visible : TilePriority.prefetch,
          ),
        );
      }
    }
  }

  bool _isStillWanted(TileCacheKey key) {
    final wanted = _wanted;
    if (wanted == null || wanted.level != key.level) return false;
    return key.tileX >= wanted.minTx &&
        key.tileX <= wanted.maxTx &&
        key.tileY >= wanted.minTy &&
        key.tileY <= wanted.maxTy;
  }

  Future<void> _decodeTile(
    SvsLevel level,
    int tx,
    int ty,
    TileCacheKey key,
    TilePriority priority,
  ) async {
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
            final data = await frame.image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            // A tile at the right/bottom edge of the level can legally
            // decode smaller than the nominal tile size — use the frame's
            // *actual* dimensions here, not level.tileWidth/tileLength, or
            // decodeImageFromPixels gets fed a buffer of the wrong length.
            final actualWidth = frame.image.width;
            final actualHeight = frame.image.height;
            frame.image.dispose();
            if (data != null) {
              final pixels = data.buffer.asUint8List(
                data.offsetInBytes,
                data.lengthInBytes,
              );
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
      if (_disposed) {
        image.dispose();
        return;
      }
      cache.put(key, image, image.width * image.height * 4);
      if (_isStillWanted(key)) notifyListeners();
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
  Future<TileWorkerResult> _fetchTileBytes(
    SvsLevel level,
    int tx,
    int ty,
    TileCacheKey key,
    TilePriority priority,
  ) async {
    TileWorkerPool? pool;
    try {
      pool = await poolFuture;
    } catch (_) {
      pool = null;
    }
    if (pool != null) {
      final handle = pool.requestTile(
        level: level.index,
        tileX: tx,
        tileY: ty,
        priority: priority,
      );
      _inFlight[key] = handle.requestId;
      return handle.result;
    }
    if (level.isJpeg) {
      final bytes = await svsFile.readTileJpegBytes(level.index, tx, ty);
      return TileWorkerResult(
        bytes: bytes.isEmpty ? null : bytes,
        isRgba: false,
      );
    }
    final rgba = await svsFile.readTileRgba(level.index, tx, ty);
    return TileWorkerResult(bytes: rgba.isEmpty ? null : rgba, isRgba: true);
  }

  static Future<ui.Image> _decodeRgba(Uint8List bytes, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  /// Cancels the pending debounce and lets already-in-flight requests be
  /// silently discarded as they land (no [notifyListeners], no write into
  /// [cache]) rather than actively cancelling every one of them — cheaper,
  /// and harmless since nothing is listening anymore.
  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    unawaited(poolFuture.then((pool) => pool.dispose(), onError: (_) {}));
    super.dispose();
  }
}
