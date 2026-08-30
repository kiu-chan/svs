import 'dart:typed_data';
import 'dart:ui' as ui;

import 'tile_cache.dart' show TileCacheKey;

/// [DiskTileCache] requires `dart:io` (`Directory`/`File`) to persist tiles
/// across app restarts, which isn't available on this platform (e.g. the
/// web, which has no filesystem). [open] always throws — pass `diskCache:
/// null` (the default) to `SvsImageView`; the in-memory `TileCache` still
/// caches recently-viewed tiles for the lifetime of the page. The instance
/// methods below are unreachable in practice, since no [DiskTileCache]
/// instance can ever be constructed — they exist only so the type itself is
/// usable wherever it's referenced (e.g. `SvsImageView`'s `diskCache`
/// parameter).
class DiskTileCache {
  DiskTileCache._();

  static Future<DiskTileCache> open(
    Object directory, {
    int maxBytes = 500 * 1024 * 1024,
  }) {
    throw UnsupportedError(
      'DiskTileCache requires dart:io (Directory/File) and is not '
      'available on the web. Omit diskCache (or pass null) when '
      'constructing SvsImageView — the in-memory TileCache is still used.',
    );
  }

  int get maxBytes =>
      throw StateError('unreachable: DiskTileCache.open always throws');

  int get currentBytes =>
      throw StateError('unreachable: DiskTileCache.open always throws');

  int get length =>
      throw StateError('unreachable: DiskTileCache.open always throws');

  bool contains(TileCacheKey key) =>
      throw StateError('unreachable: DiskTileCache.open always throws');

  Future<ui.Image?> get(TileCacheKey key) =>
      throw StateError('unreachable: DiskTileCache.open always throws');

  Future<void> put(
    TileCacheKey key,
    Uint8List rgbaBytes,
    int width,
    int height,
  ) => throw StateError('unreachable: DiskTileCache.open always throws');

  Future<void> clear() =>
      throw StateError('unreachable: DiskTileCache.open always throws');
}
