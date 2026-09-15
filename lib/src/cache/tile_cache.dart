import 'dart:ui' as ui;

import 'lru_eviction.dart';

/// Identifies one cached tile: tile ([tileX], [tileY]) of pyramid [level] —
/// or, when [span] is above 0, the composite of that level's `2^span` x
/// `2^span` tiles starting at tile (`tileX << span`, `tileY << span`).
class TileCacheKey {
  final int level;
  final int tileX;
  final int tileY;
  final int span;

  const TileCacheKey({
    required this.level,
    required this.tileX,
    required this.tileY,
    this.span = 0,
  });

  @override
  bool operator ==(Object other) =>
      other is TileCacheKey &&
      other.level == level &&
      other.tileX == tileX &&
      other.tileY == tileY &&
      other.span == span;

  @override
  int get hashCode => Object.hash(level, tileX, tileY, span);
}

class _CacheEntry {
  final ui.Image image;
  final int byteSize;
  final int reduction;

  const _CacheEntry(this.image, this.byteSize, this.reduction);
}

/// An in-memory cache of decoded tile images, bounded by decoded-pixel byte
/// budget (not item count — tile footprints vary across pyramid levels) and
/// evicted in strict least-recently-used order across all levels. Since the
/// painter re-touches every on-screen tile via [forEachInRange] once per
/// frame, currently-visible tiles are effectively pinned with no separate
/// mechanism needed for that.
///
/// Evicted images are disposed: [ui.Image] holds GPU-side memory that the
/// Dart garbage collector does not reclaim on its own.
class TileCache {
  final int maxBytes;
  final _entries = <TileCacheKey, _CacheEntry>{};
  final _groupSizes = <(int, int), int>{};
  int _currentBytes = 0;

  TileCache({this.maxBytes = 150 * 1024 * 1024});

  /// Total decoded-pixel bytes currently cached, across every tile.
  int get currentBytes => _currentBytes;

  /// Number of tiles currently cached.
  int get length => _entries.length;

  /// Every (level, span) pair with at least one tile cached — so a painter
  /// looking for a fallback only has to probe groups that exist. Don't
  /// modify the cache while iterating it.
  Iterable<(int, int)> get cachedGroups => _groupSizes.keys;

  /// Whether [key]'s tile is currently cached.
  bool contains(TileCacheKey key) => _entries.containsKey(key);

  /// Returns the cached image for [key], touching it as most-recently-used,
  /// or null if it isn't cached.
  ui.Image? get(TileCacheKey key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry; // reinsert at the end = most-recently-used
    return entry.image;
  }

  /// The reduced-decode shift [key]'s tile was cached at (0 = full
  /// resolution; see [put]), or null if it isn't cached. Doesn't touch it.
  int? reductionOf(TileCacheKey key) => _entries[key]?.reduction;

  /// Stores [image] (already decoded, [byteSize] bytes of pixel data) under
  /// [key], evicting least-recently-used entries first if needed to stay
  /// within [maxBytes].
  ///
  /// [reduction] records that each of [image]'s pixels covers `2^reduction`
  /// of its level's texels per side, so the painter can still size it to
  /// its full on-slide footprint.
  void put(
    TileCacheKey key,
    ui.Image image,
    int byteSize, {
    int reduction = 0,
  }) {
    final existing = _entries.remove(key);
    if (existing != null) _discard(key, existing);

    final victims = pickEvictions(
      _entries.keys,
      (k) => _entries[k]!.byteSize,
      currentBytes: _currentBytes,
      maxBytes: maxBytes,
      reserve: byteSize,
    );
    for (final k in victims) {
      _discard(k, _entries.remove(k)!);
    }

    _entries[key] = _CacheEntry(image, byteSize, reduction);
    _currentBytes += byteSize;
    final group = (key.level, key.span);
    _groupSizes[group] = (_groupSizes[group] ?? 0) + 1;
  }

  void _discard(TileCacheKey key, _CacheEntry entry) {
    _currentBytes -= entry.byteSize;
    entry.image.dispose();
    final group = (key.level, key.span);
    final remaining = _groupSizes[group]! - 1;
    if (remaining == 0) {
      _groupSizes.remove(group);
    } else {
      _groupSizes[group] = remaining;
    }
  }

  /// How many of [level]'s tiles (composites, if [span] is above 0) in the
  /// inclusive range [minTx]..[maxTx] x [minTy]..[maxTy] are cached. Doesn't
  /// touch them.
  ///
  /// Costs O(min(range size, [length])) — see [forEachInRange].
  int countInRange(
    int level,
    int minTx,
    int maxTx,
    int minTy,
    int maxTy, {
    int span = 0,
  }) {
    var count = 0;
    _visitRange(level, span, minTx, maxTx, minTy, maxTy, (_, _) => count++);
    return count;
  }

  /// Calls [visit] with every cached tile of [level] (composites, if [span]
  /// is above 0) in the inclusive range [minTx]..[maxTx] x [minTy]..[maxTy],
  /// touching each as most-recently-used.
  ///
  /// Walks whichever is smaller: the range's tile grid, or the cache's own
  /// entries. A zoomed-out view can span tens of thousands of a fine
  /// level's tiles while the cache only ever holds a few hundred — probing
  /// every grid cell on every frame would stall the UI for nothing.
  void forEachInRange(
    int level,
    int minTx,
    int maxTx,
    int minTy,
    int maxTy,
    void Function(TileCacheKey key, ui.Image image, int reduction) visit, {
    int span = 0,
  }) {
    final hits = <(TileCacheKey, _CacheEntry)>[];
    _visitRange(
      level,
      span,
      minTx,
      maxTx,
      minTy,
      maxTy,
      (key, entry) => hits.add((key, entry)),
    );
    for (final (key, entry) in hits) {
      _entries.remove(key);
      _entries[key] = entry;
      visit(key, entry.image, entry.reduction);
    }
  }

  void _visitRange(
    int level,
    int span,
    int minTx,
    int maxTx,
    int minTy,
    int maxTy,
    void Function(TileCacheKey key, _CacheEntry entry) visit,
  ) {
    final rangeSize = (maxTx - minTx + 1) * (maxTy - minTy + 1);
    if (rangeSize <= 0 || !_groupSizes.containsKey((level, span))) return;
    if (rangeSize <= _entries.length) {
      for (var ty = minTy; ty <= maxTy; ty++) {
        for (var tx = minTx; tx <= maxTx; tx++) {
          final key = TileCacheKey(
            level: level,
            tileX: tx,
            tileY: ty,
            span: span,
          );
          final entry = _entries[key];
          if (entry != null) visit(key, entry);
        }
      }
    } else {
      for (final MapEntry(:key, :value) in _entries.entries) {
        if (key.level == level &&
            key.span == span &&
            key.tileX >= minTx &&
            key.tileX <= maxTx &&
            key.tileY >= minTy &&
            key.tileY <= maxTy) {
          visit(key, value);
        }
      }
    }
  }

  /// Disposes every cached image and resets byte accounting to zero. The
  /// target for an OS memory-pressure signal.
  void clear() {
    for (final entry in _entries.values) {
      entry.image.dispose();
    }
    _entries.clear();
    _groupSizes.clear();
    _currentBytes = 0;
  }
}
