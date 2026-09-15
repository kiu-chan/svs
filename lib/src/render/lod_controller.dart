import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Size;

import '../cache/disk_tile_cache.dart';
import '../cache/tile_cache.dart';
import '../io/tile_worker_pool.dart';
import '../svs/svs_file.dart';
import 'viewport_math.dart';

/// Decides which tiles a given viewport needs, fetches/decodes them (off the
/// main isolate where possible — see [TileWorkerPool]), writes decoded tiles
/// into [cache], and cancels requests that fall out of range before they
/// finish. Calls [notifyListeners] whenever a newly decoded tile lands in
/// [cache] and is still wanted, so a listener can trigger a repaint.
///
/// Resource use is bounded however large the slide:
/// * Tiles whose texels are denser than the screen can show are decoded at
///   a reduced resolution (see [selectReduction]), and tiles that would be
///   drawn under [minTileScreenSize] are merged into composite tiles (see
///   [selectSpan]) — so a viewport's tile count and decoded bytes track the
///   screen, not the slide, even when its pyramid is too shallow.
/// * A viewport never wants more decoded bytes than [cacheBudgetFraction] of
///   [cache] holds, nor more than [maxWantedTiles] tiles — nearest its
///   center first, prefetch margin dropped first.
/// * At most two requests per worker isolate are in flight at once. The
///   rest wait in a queue that's rebuilt, not appended to, on every viewport
///   change, so a fast pan never leaves a backlog of stale work behind it.
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
  /// fall back to running directly on the main isolate — one at a time,
  /// yielding to the event loop between tiles — instead of bricking the
  /// whole view. Overridable so tests can inject an already-spawned pool
  /// instead of paying isolate-spawn cost per test.
  final Future<TileWorkerPool> poolFuture;

  /// When set, decoded tiles are read from here first (skipping the fetch
  /// and decode entirely on a hit) and written back here after a fresh
  /// decode — see [DiskTileCache].
  final DiskTileCache? diskCache;

  /// The most tiles (or composites) one viewport may want at once — beyond
  /// this, only the ones nearest its center are fetched. A safety net:
  /// composites already keep the count proportional to the viewport's size.
  final int maxWantedTiles;

  /// The share of [cache]'s byte budget one viewport's wanted tiles may
  /// fill. The rest is headroom for the fallback level still painted
  /// underneath while they load, so the two never evict each other.
  final double cacheBudgetFraction;

  LodController({
    required this.svsFile,
    required this.cache,
    this.maxUpsample = 1.3,
    this.prefetchMargin = 1,
    this.diskCache,
    this.maxWantedTiles = 4096,
    this.cacheBudgetFraction = 0.8,
    Future<TileWorkerPool>? pool,
  }) : poolFuture =
           pool ??
           (svsFile.path != null
               ? TileWorkerPool.spawn(svsFile.path!)
               : Future<TileWorkerPool>.error(
                   UnsupportedError(
                     'SvsFile has no filesystem path (opened via '
                     'openBytes); tiles are fetched/decoded on the calling '
                     'isolate instead.',
                   ),
                 )) {
    poolFuture.then(
      (pool) {
        _maxInFlight = pool.workerCount * 2;
        _pump();
      },
      onError: (_) {
        _maxInFlight = 1;
        _onCallingIsolate = true;
      },
    );
  }

  /// How long a [handleMemoryPressure] signal keeps the budget halved and
  /// the prefetch margin off.
  static const memoryPressureCooldown = Duration(seconds: 30);

  /// The deepest reduced decode a single tile gets — as far as `dart:ui`'s
  /// scaled JPEG decode goes before it has to resize.
  static const _maxTileReduction = 3;

  /// Composite pixels may cover far more texels than that: member tiles are
  /// decoded at [_maxTileReduction] and scaled down the rest of the way as
  /// they're drawn in.
  static const _maxCompositeReduction = 16;

  /// At most this many decoded tiles wait on their (serialized) GPU readback
  /// and disk write at once; tiles beyond it just aren't persisted.
  static const _maxPersistBacklog = 8;

  /// Sparse (zero-byte) tiles remembered so they aren't re-requested on
  /// every viewport change, up to this many before the memo resets.
  static const _maxSparseMemo = 65536;

  final Map<TileCacheKey, _TileRequest> _inFlight = {};
  List<_TileRequest> _queue = [];
  int _queueHead = 0;
  Map<TileCacheKey, TilePriority> _wanted = const {};
  int _wantedReduction = 0;
  final Set<TileCacheKey> _sparse = {};
  int _maxInFlight = 2;
  bool _onCallingIsolate = false;
  Stopwatch? _memoryPressure;
  Future<void> _persistQueue = Future.value();
  int _persistBacklog = 0;
  Timer? _debounce;
  bool _disposed = false;

  /// Tiles currently being fetched or decoded.
  @visibleForTesting
  int get inFlightCount => _inFlight.length;

  /// Tiles the last viewport change asked for (fetched or not).
  @visibleForTesting
  int get wantedCount => _wanted.length;

  /// Tiles waiting for a free in-flight slot.
  @visibleForTesting
  int get queuedCount => _queue.length - _queueHead;

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

  /// The OS asked this app to free memory: for [memoryPressureCooldown],
  /// viewports want half as many decoded bytes and skip the prefetch margin
  /// — so re-fetching the visible tiles right after the caller clears
  /// [cache] doesn't immediately climb back to the level that triggered the
  /// signal.
  void handleMemoryPressure() {
    _memoryPressure = Stopwatch()..start();
    _queue = [];
    _queueHead = 0;
  }

  bool get _underMemoryPressure {
    final since = _memoryPressure;
    if (since == null) return false;
    if (since.elapsed < memoryPressureCooldown) return true;
    _memoryPressure = null;
    return false;
  }

  void _refreshTiles(Size viewportSize, double scale, Offset origin) {
    if (_disposed) return;
    final levels = svsFile.levels;
    final level =
        levels[selectLevel(
          levels.map((l) => l.geometry).toList(growable: false),
          scale,
          maxUpsample: maxUpsample,
        )];
    final screenPixelsPerTexel = level.downsample * scale;
    final span = selectSpan(
      math.min(level.tileWidth, level.tileLength) * screenPixelsPerTexel,
    );
    final grid = spanGeometry(level.geometry, span);
    final reduction = selectReduction(
      screenPixelsPerTexel,
      maxUpsample: maxUpsample,
      maxReduction: span == 0 ? _maxTileReduction : _maxCompositeReduction,
    );
    final tileBytes =
        reducedTileExtent(grid.tileWidth, reduction) *
        reducedTileExtent(grid.tileLength, reduction) *
        4;
    final pressured = _underMemoryPressure;
    final budgetBytes =
        cache.maxBytes * cacheBudgetFraction * (pressured ? 0.5 : 1);
    final limit = math.max(
      1,
      math.min(maxWantedTiles, budgetBytes ~/ tileBytes),
    );

    final centerLevel0 =
        origin + Offset(viewportSize.width, viewportSize.height) / (2 * scale);
    final centerTx = centerLevel0.dx / level.downsample / grid.tileWidth;
    final centerTy = centerLevel0.dy / level.downsample / grid.tileLength;

    // The strictly-on-screen range vs. the range expanded by the prefetch
    // margin — on-screen tiles are routed to the "visible" workers so they
    // never queue behind prefetch-margin ones (see TileWorkerPool), and are
    // the last to be dropped when the budget runs out.
    final core = computeVisibleTiles(grid, viewportSize, scale, origin);
    final coreTiles = tilesNearestFirst(core, centerTx, centerTy, limit);
    final prefetchTiles = pressured || coreTiles.length >= limit
        ? const <(int, int)>[]
        : tilesNearestFirst(
            computeVisibleTiles(
              grid,
              viewportSize,
              scale,
              origin,
              margin: prefetchMargin,
            ),
            centerTx,
            centerTy,
            limit - coreTiles.length,
            exclude: core,
          );

    TileCacheKey keyOf((int, int) tile) => TileCacheKey(
      level: level.index,
      tileX: tile.$1,
      tileY: tile.$2,
      span: span,
    );
    final wanted = <TileCacheKey, TilePriority>{
      for (final tile in coreTiles) keyOf(tile): TilePriority.visible,
      for (final tile in prefetchTiles) keyOf(tile): TilePriority.prefetch,
    };
    _wanted = wanted;
    _wantedReduction = reduction;

    // Anything still in flight for a tile we no longer want (scrolled out
    // of range, or the target level changed) gets actively cancelled —
    // otherwise it'd keep occupying a worker for a result nobody will use.
    final stale = [
      for (final request in _inFlight.values)
        if (!wanted.containsKey(request.key)) request,
    ];
    for (final request in stale) {
      _inFlight.remove(request.key);
      _cancel(request);
    }

    _queue = [
      for (final MapEntry(:key, :value) in wanted.entries)
        if (_needsFetch(key, reduction))
          _TileRequest(level, key, value, reduction),
    ];
    _queueHead = 0;
    _pump();
  }

  /// Whether [key] still has to be fetched to show it at [reduction] — not
  /// if it's already on its way, known to be sparse, or cached at least that
  /// sharp.
  bool _needsFetch(TileCacheKey key, int reduction) {
    if (_inFlight.containsKey(key) || _sparse.contains(key)) return false;
    final cached = cache.reductionOf(key);
    return cached == null || cached > reduction;
  }

  bool _isCurrent(_TileRequest request) =>
      !_disposed && identical(_inFlight[request.key], request);

  void _markSparse(TileCacheKey key) {
    if (_sparse.length >= _maxSparseMemo) _sparse.clear();
    _sparse.add(key);
  }

  void _cancel(_TileRequest request) {
    final requestId = request.requestId;
    if (requestId == null) return; // _fetch cancels it once issued
    unawaited(
      poolFuture.then((pool) => pool.cancel(requestId), onError: (_) {}),
    );
  }

  /// Starts queued requests until every in-flight slot is taken.
  void _pump() {
    while (!_disposed &&
        _inFlight.length < _maxInFlight &&
        _queueHead < _queue.length) {
      final request = _queue[_queueHead++];
      if (!_wanted.containsKey(request.key) ||
          !_needsFetch(request.key, request.reduction)) {
        continue;
      }
      _inFlight[request.key] = request;
      unawaited(_load(request));
    }
    if (_queueHead >= _queue.length && _queue.isNotEmpty) {
      _queue = [];
      _queueHead = 0;
    }
  }

  Future<void> _load(_TileRequest request) async {
    final key = request.key;
    ui.Image? image;
    var reduction = request.reduction;
    var fromDisk = false;
    try {
      if (key.span > 0) {
        final (composite, sparse) = await _loadComposite(request);
        image = composite;
        if (sparse) _markSparse(key);
      } else {
        final disk = diskCache;
        // The disk cache only holds full-resolution tiles — a hit for a tile
        // wanted reduced would overshoot the byte budget it was planned with.
        if (disk != null && reduction == 0) {
          image = await disk.get(key);
          fromDisk = image != null;
        }
        if (image == null) {
          final (tile, landed) = await _fetchTileImage(
            request,
            key.tileX,
            key.tileY,
            reduction,
          );
          if (tile == null) {
            _markSparse(key);
          } else {
            image = tile;
            reduction = landed;
          }
        }
      }
    } catch (_) {
      // Leave this tile blank rather than letting one bad tile (or a
      // cancelled request) crash the view.
    }

    if (identical(_inFlight[key], request)) _inFlight.remove(key);
    if (image != null) _store(request, image, reduction, fromDisk);
    if (_onCallingIsolate) {
      // Each calling-isolate fetch can block for a whole JPEG2000 decode —
      // let a frame through before starting the next one.
      Timer.run(_pump);
    } else {
      _pump();
    }
  }

  /// Fetches tile ([tx], [ty]) of [request]'s level and decodes it at
  /// `1 / 2^reduction` of its stored size, returning the image (null for a
  /// sparse tile) and the reduction it actually landed at.
  Future<(ui.Image?, int)> _fetchTileImage(
    _TileRequest request,
    int tx,
    int ty,
    int reduction,
  ) async {
    final level = request.level;
    final result = await _fetch(request, tx, ty, reduction);
    final bytes = result.bytes;
    if (bytes == null) return (null, reduction);
    if (result.isRgba) {
      // JPEG2000: already decoded to RGBA by the worker (via openjpeg_ffi,
      // which has no main-isolate restriction). Aperio's JP2K tiles are
      // always encoded at the full nominal tile-grid size (unlike JPEG, a
      // boundary tile can't come back cropped), so the reduced nominal size
      // is the correct buffer shape.
      final landed = result.reduction;
      final image = await _decodeRgba(
        bytes,
        reducedTileExtent(level.tileWidth, landed),
        reducedTileExtent(level.tileLength, landed),
      );
      return (image, landed);
    }
    // JPEG: the worker only spliced/RGB-patched the standalone bytes (see
    // [SvsLevel.readTileJpegBytes]) — the actual decode must happen here,
    // `dart:ui`'s codec APIs only work on the main isolate
    // (flutter/flutter#109701).
    return (await _decodeJpeg(bytes, reduction), reduction);
  }

  /// Builds [request]'s composite: each of its member tiles decoded at up to
  /// 1/8 resolution and drawn in, scaled to the composite's own
  /// `1 / 2^reduction` — with the result rasterized after every row of
  /// members, so only one row's decoded tiles are ever held at once however
  /// many the composite spans.
  ///
  /// Returns the composite (null if abandoned or empty) and whether it's
  /// known to be empty — every member sparse, none failed.
  Future<(ui.Image?, bool)> _loadComposite(_TileRequest request) async {
    final level = request.level;
    final key = request.key;
    final span = key.span;
    final reduction = request.reduction;
    final memberReduction = math.min(reduction, _maxTileReduction);
    final firstTx = key.tileX << span;
    final firstTy = key.tileY << span;
    final lastTx = math.min(firstTx + (1 << span), level.tilesAcrossX) - 1;
    final lastTy = math.min(firstTy + (1 << span), level.tilesAcrossY) - 1;
    final width = reducedTileExtent(
      math.min(level.width, (lastTx + 1) * level.tileWidth) -
          firstTx * level.tileWidth,
      reduction,
    );
    final height = reducedTileExtent(
      math.min(level.height, (lastTy + 1) * level.tileLength) -
          firstTy * level.tileLength,
      reduction,
    );
    final texelsPerPixel = (1 << reduction).toDouble();
    // Same seam handling as the view's own tile painter: no anti-aliasing,
    // and a one-pixel overlap into the next member.
    final paint = ui.Paint()
      ..filterQuality = ui.FilterQuality.medium
      ..isAntiAlias = false;

    ui.Image? composite;
    var sparse = true;
    try {
      for (var ty = firstTy; ty <= lastTy; ty++) {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        final members = <ui.Image>[];
        try {
          if (composite != null) {
            canvas.drawImage(composite, ui.Offset.zero, paint);
          }
          for (var tx = firstTx; tx <= lastTx; tx++) {
            if (!_isCurrent(request)) return (null, false);
            if (_onCallingIsolate) await Future<void>.delayed(Duration.zero);
            (ui.Image?, int) fetched;
            try {
              fetched = await _fetchTileImage(request, tx, ty, memberReduction);
            } catch (_) {
              if (!_isCurrent(request)) return (null, false);
              sparse = false;
              continue; // leave this member blank
            }
            final (member, landed) = fetched;
            if (member == null) continue;
            sparse = false;
            members.add(member);
            final scaleIn = (1 << landed) / texelsPerPixel;
            canvas.drawImageRect(
              member,
              ui.Rect.fromLTWH(
                0,
                0,
                member.width.toDouble(),
                member.height.toDouble(),
              ),
              ui.Rect.fromLTWH(
                (tx - firstTx) * level.tileWidth / texelsPerPixel,
                (ty - firstTy) * level.tileLength / texelsPerPixel,
                member.width * scaleIn + 1,
                member.height * scaleIn + 1,
              ),
              paint,
            );
          }
          if (members.isEmpty) continue;
          final picture = recorder.endRecording();
          try {
            final next = await picture.toImage(width, height);
            composite?.dispose();
            composite = next;
          } finally {
            picture.dispose();
          }
        } finally {
          if (recorder.isRecording) recorder.endRecording().dispose();
          for (final member in members) {
            member.dispose();
          }
        }
      }
      final result = composite;
      composite = null;
      return (result, result == null && sparse);
    } finally {
      composite?.dispose();
    }
  }

  void _store(
    _TileRequest request,
    ui.Image image,
    int reduction,
    bool fromDisk,
  ) {
    final key = request.key;
    if (_disposed) {
      image.dispose();
      return;
    }
    final byteSize = image.width * image.height * 4;
    final wanted = _wanted.containsKey(key);
    final cachedReduction = cache.reductionOf(key);
    // A result the viewport stopped wanting is only kept if it fits without
    // evicting anything — it must never push out tiles the current viewport
    // is still waiting on. Nor may any result replace a sharper copy.
    if ((!wanted && cache.currentBytes + byteSize > cache.maxBytes) ||
        (cachedReduction != null && cachedReduction < reduction)) {
      image.dispose();
      return;
    }

    // No `await` between here and notifyListeners — otherwise a dispose
    // (or a re-triggered fetch of this same key, now that it's neither
    // in-flight nor cached) could race in through the gap.
    cache.put(key, image, byteSize, reduction: reduction);
    if (!wanted) return;
    notifyListeners();

    if (reduction > _wantedReduction) {
      // Landed blurrier than the viewport now needs (it zoomed in while
      // this was in flight) — keep it on screen, but fetch a sharper one.
      _queue.add(
        _TileRequest(request.level, key, request.priority, _wantedReduction),
      );
    }

    // Persist a freshly-decoded tile (not one that just came from the disk
    // cache itself) *after* the tile is already visible — the GPU pixel
    // readback this needs shouldn't delay the tile's first paint. Only for
    // full-resolution single tiles that are actually on screen, not ones
    // fetched just for the prefetch margin — a tile scrolled back out of
    // view before it's ever painted would otherwise still pay a full GPU
    // readback and disk write for nothing. (The disk cache's file names
    // don't encode a span, so composites must never reach it.)
    final disk = diskCache;
    if (disk != null &&
        !fromDisk &&
        reduction == 0 &&
        key.span == 0 &&
        request.priority == TilePriority.visible) {
      _schedulePersist(disk, key, image);
    }
  }

  /// Readbacks run one at a time: each one stalls the raster thread for the
  /// length of a GPU copy, and a burst of them (a freshly loaded viewport)
  /// would otherwise land as a visible hitch.
  void _schedulePersist(DiskTileCache disk, TileCacheKey key, ui.Image image) {
    if (_persistBacklog >= _maxPersistBacklog) return;
    _persistBacklog++;
    // A handle of our own, so an eviction disposing the cache's handle in
    // the meantime doesn't take the pixels out from under the readback.
    final handle = image.clone();
    _persistQueue = _persistQueue.then((_) async {
      try {
        if (!_disposed) await _persistToDisk(disk, key, handle);
      } finally {
        handle.dispose();
        _persistBacklog--;
      }
    });
  }

  /// Best-effort: a failure here just means this tile isn't cached to disk,
  /// not a decode failure.
  Future<void> _persistToDisk(
    DiskTileCache disk,
    TileCacheKey key,
    ui.Image image,
  ) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return;
      await disk.put(
        key,
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        image.width,
        image.height,
      );
    } catch (_) {
      // See doc comment above.
    }
  }

  /// Fetches tile ([tx], [ty]) of [request]'s level — [request]'s own tile,
  /// or one member of its composite. Routes through the isolate pool; if the
  /// pool itself never became available (spawn failed), falls back to
  /// fetching directly on the main isolate rather than leaving every tile
  /// permanently blank. Records the pool request's id on [request] as soon
  /// as it's known, so [_refreshTiles] can actively [TileWorkerPool.cancel]
  /// it later.
  Future<TileWorkerResult> _fetch(
    _TileRequest request,
    int tx,
    int ty,
    int reduction,
  ) async {
    TileWorkerPool? pool;
    try {
      pool = await poolFuture;
    } catch (_) {
      pool = null;
    }
    if (pool == null) {
      return fetchTile(request.level, tx, ty, reduction: reduction);
    }
    final handle = pool.requestTile(
      level: request.level.index,
      tileX: tx,
      tileY: ty,
      priority: request.priority,
      reduction: reduction,
    );
    request.requestId = handle.requestId;
    // Dropped by a viewport change while the pool was still spawning.
    if (!identical(_inFlight[request.key], request)) {
      pool.cancel(handle.requestId);
    }
    return handle.result;
  }

  /// Decodes at `1 / 2^reduction` of the tile's stored size — `dart:ui`'s
  /// JPEG codec can do that with a scaled IDCT, well before any pixels are
  /// materialized at full size.
  static Future<ui.Image> _decodeJpeg(Uint8List bytes, int reduction) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) => reduction == 0
          ? const ui.TargetImageSize()
          : ui.TargetImageSize(
              width: reducedTileExtent(width, reduction),
              height: reducedTileExtent(height, reduction),
            ),
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      // Holds its own copy of the encoded bytes natively until disposed (or
      // eventually finalized) — invisible to the Dart GC's memory pressure.
      codec.dispose();
    }
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

  /// Cancels the pending debounce and queue, and lets already-in-flight
  /// requests be silently discarded as they land (no [notifyListeners], no
  /// write into [cache]) rather than actively cancelling every one of them —
  /// cheaper, and harmless since nothing is listening anymore.
  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _queue = [];
    _queueHead = 0;
    unawaited(poolFuture.then((pool) => pool.dispose(), onError: (_) {}));
    super.dispose();
  }
}

class _TileRequest {
  final SvsLevel level;

  /// The tile — or, when `key.span` is above 0, the composite — to load.
  final TileCacheKey key;
  final TilePriority priority;
  final int reduction;

  /// The pool's id for this request (for a composite, its latest member's),
  /// once issued.
  int? requestId;

  _TileRequest(this.level, this.key, this.priority, this.reduction);
}
