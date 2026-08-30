import 'dart:typed_data';

/// Which queue a tile request goes to — see `TileWorkerPool`.
enum TilePriority { visible, prefetch }

/// A decoded (or decode-ready) tile from a `TileWorkerPool` request.
///
/// [bytes] is standalone JPEG bytes needing a `dart:ui` decode on the main
/// isolate when [isRgba] is false, or already-decoded tightly-packed
/// RGBA8888 bytes when [isRgba] is true. Null [bytes] means a sparse
/// (blank) tile.
class TileWorkerResult {
  final Uint8List? bytes;
  final bool isRgba;
  const TileWorkerResult({required this.bytes, required this.isRgba});
}

/// A tile fetch in flight: [requestId] is returned synchronously so the
/// caller can `TileWorkerPool.cancel` it later (e.g. once the tile scrolls
/// out of view) without waiting on [result] first.
class TileRequestHandle {
  final int requestId;
  final Future<TileWorkerResult> result;
  const TileRequestHandle({required this.requestId, required this.result});
}

/// Thrown to reject [TileRequestHandle.result] when `TileWorkerPool.cancel`
/// is called for that request.
class TileRequestCancelledException implements Exception {
  const TileRequestCancelledException();
  @override
  String toString() => 'TileRequestCancelledException';
}
