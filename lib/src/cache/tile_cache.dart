import 'dart:ui' as ui;

import 'lru_eviction.dart';

class TileCacheKey {
  final int level;
  final int tileX;
  final int tileY;

  const TileCacheKey({
    required this.level,
    required this.tileX,
    required this.tileY,
  });

  @override
  bool operator ==(Object other) =>
      other is TileCacheKey &&
      other.level == level &&
      other.tileX == tileX &&
      other.tileY == tileY;

  @override
  int get hashCode => Object.hash(level, tileX, tileY);
}

class _CacheEntry {
  final ui.Image image;
  final int byteSize;

  const _CacheEntry(this.image, this.byteSize);
}

/// An in-memory cache of decoded tile images, bounded by decoded-pixel byte
/// budget (not item count — tile footprints vary across pyramid levels) and
/// evicted in strict least-recently-used order across all levels. Since the
/// painter re-touches every on-screen tile via [get] once per frame,
/// currently-visible tiles are effectively pinned with no separate mechanism
/// needed for that.
///
/// Evicted images are disposed: [ui.Image] holds GPU-side memory that the
/// Dart garbage collector does not reclaim on its own.
class TileCache {
  final int maxBytes;
  final _entries = <TileCacheKey, _CacheEntry>{};
  int _currentBytes = 0;

  TileCache({this.maxBytes = 150 * 1024 * 1024});

  /// Total decoded-pixel bytes currently cached, across every tile.
  int get currentBytes => _currentBytes;

  /// Number of tiles currently cached.
  int get length => _entries.length;

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

  /// Stores [image] (already decoded, [byteSize] bytes of pixel data) under
  /// [key], evicting least-recently-used entries first if needed to stay
  /// within [maxBytes].
  void put(TileCacheKey key, ui.Image image, int byteSize) {
    final existing = _entries.remove(key);
    if (existing != null) {
      _currentBytes -= existing.byteSize;
      existing.image.dispose();
    }

    final victims = pickEvictions(
      _entries.keys,
      (k) => _entries[k]!.byteSize,
      currentBytes: _currentBytes,
      maxBytes: maxBytes,
      reserve: byteSize,
    );
    for (final k in victims) {
      final oldest = _entries.remove(k)!;
      _currentBytes -= oldest.byteSize;
      oldest.image.dispose();
    }

    _entries[key] = _CacheEntry(image, byteSize);
    _currentBytes += byteSize;
  }

  /// Disposes every cached image and resets byte accounting to zero. The
  /// target for an OS memory-pressure signal.
  void clear() {
    for (final entry in _entries.values) {
      entry.image.dispose();
    }
    _entries.clear();
    _currentBytes = 0;
  }
}
