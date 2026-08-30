import 'tile_worker_types.dart';

/// No background-isolate implementation on this platform (e.g. the web,
/// which has no `Isolate.spawn`) — [spawn] always rejects, so
/// `LodController` falls back to fetching/decoding tiles on the calling
/// isolate instead (its `poolFuture` error handling already treats a
/// rejected pool exactly this way). The instance methods below are
/// unreachable in practice, since no [TileWorkerPool] instance can ever be
/// constructed — they exist only so the type itself is usable wherever it's
/// referenced (e.g. `LodController`'s `Future<TileWorkerPool>?` parameter).
class TileWorkerPool {
  TileWorkerPool._();

  static Future<TileWorkerPool> spawn(String path, {int workerCount = 2}) {
    return Future.error(
      UnsupportedError(
        'TileWorkerPool (background-isolate tile fetching) is not '
        'supported on this platform — tiles are fetched/decoded on the '
        'calling isolate instead.',
      ),
    );
  }

  TileRequestHandle requestTile({
    required int level,
    required int tileX,
    required int tileY,
    TilePriority priority = TilePriority.visible,
  }) => throw StateError('unreachable: TileWorkerPool.spawn always rejects');

  void cancel(int requestId) {}

  Future<void> dispose() async {}
}
