import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'tile_cache.dart' show TileCacheKey;

/// A disk-backed cache of decoded tile pixels, so re-opening the same slide
/// — even across app restarts — can skip both the tile fetch and, for
/// JPEG2000 slides whose wavelet decode is comparatively expensive, the
/// decode itself.
///
/// Bounded by decoded-pixel byte budget and evicted LRU, same policy as
/// [TileCache] — but since files on disk carry no in-process access order,
/// [open] seeds it from each file's on-disk modification time instead, so
/// eviction order survives a restart approximately, not exactly.
///
/// Each tile is one file under [directory], named from its [TileCacheKey] —
/// point different slides at *different* directories (e.g. one named after
/// the slide's own file path/hash), since keys only distinguish
/// level/tile-x/tile-y, not which slide they belong to.
class DiskTileCache {
  /// The directory each tile is stored under, as set via [open].
  final Directory directory;

  /// The decoded-pixel byte budget, as set via [open].
  final int maxBytes;

  final _entries = <TileCacheKey, _DiskEntry>{};
  int _currentBytes = 0;

  DiskTileCache._(this.directory, this.maxBytes);

  /// Total decoded-pixel bytes currently on disk, across every cached tile.
  int get currentBytes => _currentBytes;

  /// Number of tiles currently cached on disk.
  int get length => _entries.length;

  /// Whether [key]'s tile is currently cached on disk.
  bool contains(TileCacheKey key) => _entries.containsKey(key);

  /// Opens (creating if needed) a disk cache rooted at [directory],
  /// rebuilding its LRU index from whatever tile files are already there.
  static Future<DiskTileCache> open(
    Directory directory, {
    int maxBytes = 500 * 1024 * 1024,
  }) async {
    await directory.create(recursive: true);
    final cache = DiskTileCache._(directory, maxBytes);

    final found = <(TileCacheKey, File, DateTime, int)>[];
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final key = _parseFileName(entity.uri.pathSegments.last);
      if (key == null) continue;
      final stat = await entity.stat();
      found.add((key, entity, stat.modified, stat.size));
    }
    found.sort((a, b) => a.$3.compareTo(b.$3)); // oldest mtime first

    for (final (key, file, _, size) in found) {
      cache._entries[key] = _DiskEntry(file: file, byteSize: size);
      cache._currentBytes += size;
    }
    await cache._evictIfNeeded();
    return cache;
  }

  /// Reads and decodes the cached tile for [key], touching it as
  /// most-recently-used. Returns null on a cache miss — including a read or
  /// decode failure, treated as a miss rather than thrown, since a
  /// persistent cache is a speed optimization the caller should transparently
  /// fall back from.
  Future<ui.Image?> get(TileCacheKey key) async {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry; // reinsert at the end = most-recently-used

    try {
      final raw = await entry.file.readAsBytes();
      final header = ByteData.sublistView(raw, 0, _headerBytes);
      final width = header.getUint32(0, Endian.little);
      final height = header.getUint32(4, Endian.little);
      final pixels = Uint8List.sublistView(raw, _headerBytes);
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return await completer.future;
    } catch (_) {
      return null;
    }
  }

  static const _headerBytes = 8;

  /// Writes [rgbaBytes] (tightly packed, [width]x[height] RGBA8888) to disk
  /// under [key], evicting least-recently-used entries first if needed to
  /// stay within [maxBytes]. A write failure (e.g. disk full) is swallowed —
  /// this tile is simply not persisted, same as a miss on next [get].
  Future<void> put(
    TileCacheKey key,
    Uint8List rgbaBytes,
    int width,
    int height,
  ) async {
    final payload = Uint8List(_headerBytes + rgbaBytes.length);
    // A view over payload's own buffer — writes below land directly in it.
    ByteData.sublistView(payload, 0, _headerBytes)
      ..setUint32(0, width, Endian.little)
      ..setUint32(4, height, Endian.little);
    payload.setRange(_headerBytes, _headerBytes + rgbaBytes.length, rgbaBytes);

    final file = File('${directory.path}/${_fileName(key)}');
    try {
      await file.writeAsBytes(payload, flush: false);
    } catch (_) {
      return;
    }

    final existing = _entries.remove(key);
    if (existing != null) _currentBytes -= existing.byteSize;

    // Evict *before* inserting the new entry, same as TileCache.put — so a
    // single tile larger than maxBytes on its own is kept (temporarily
    // exceeding the budget) rather than being deleted the instant it's
    // written, and eviction only ever touches other, older entries.
    await _evictIfNeeded(reserve: payload.length);

    _entries[key] = _DiskEntry(file: file, byteSize: payload.length);
    _currentBytes += payload.length;
  }

  Future<void> _evictIfNeeded({int reserve = 0}) async {
    while (_entries.isNotEmpty && _currentBytes + reserve > maxBytes) {
      final oldest = _entries.remove(_entries.keys.first)!;
      _currentBytes -= oldest.byteSize;
      try {
        await oldest.file.delete();
      } catch (_) {
        // Already gone, or not deletable — the index no longer counts it
        // either way.
      }
    }
  }

  /// Deletes every cached tile file and resets the index.
  Future<void> clear() async {
    for (final entry in _entries.values) {
      try {
        await entry.file.delete();
      } catch (_) {}
    }
    _entries.clear();
    _currentBytes = 0;
  }

  static String _fileName(TileCacheKey key) =>
      'L${key.level}_X${key.tileX}_Y${key.tileY}.tile';

  static final _fileNamePattern = RegExp(r'^L(\d+)_X(\d+)_Y(\d+)\.tile$');

  static TileCacheKey? _parseFileName(String name) {
    final match = _fileNamePattern.firstMatch(name);
    if (match == null) return null;
    return TileCacheKey(
      level: int.parse(match.group(1)!),
      tileX: int.parse(match.group(2)!),
      tileY: int.parse(match.group(3)!),
    );
  }
}

class _DiskEntry {
  final File file;
  final int byteSize;
  const _DiskEntry({required this.file, required this.byteSize});
}
