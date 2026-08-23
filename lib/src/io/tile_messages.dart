import 'dart:typed_data';

/// Sent from main to a worker isolate once, right after spawn: open the SVS
/// file at [path] before servicing any tile requests.
class OpenFileMessage {
  final String path;
  const OpenFileMessage(this.path);
}

/// Sent from a worker back to main in reply to [OpenFileMessage].
class FileOpenedMessage {
  final bool ok;
  final String? error;
  const FileOpenedMessage({required this.ok, this.error});
}

/// Sent from main to a worker: decode tile ([tileX], [tileY]) of [level].
class TileRequestMessage {
  final int requestId;
  final int level;
  final int tileX;
  final int tileY;
  const TileRequestMessage({
    required this.requestId,
    required this.level,
    required this.tileX,
    required this.tileY,
  });
}

/// Sent from main to a worker: if [requestId] hasn't been started yet,
/// don't bother — best-effort only, checked at dequeue time (see
/// `TileWorkerPool`'s doc comment for why this can't be stronger).
class CancelTileMessage {
  final int requestId;
  const CancelTileMessage(this.requestId);
}

/// Sent from a worker back to main in reply to a [TileRequestMessage].
///
/// [bytes] is standalone (spliced) JPEG bytes when [isRgba] is false — the
/// receiver still needs `dart:ui` to decode it (main-isolate-only) — or
/// already-decoded, tightly-packed RGBA8888 bytes when [isRgba] is true
/// (the JPEG2000 path, decoded via `openjpeg_ffi` inside the worker, which
/// has no such isolate restriction). Null [bytes] means a sparse tile
/// (blank) or [error] is set.
class TileResponseMessage {
  final int requestId;
  final Uint8List? bytes;
  final bool isRgba;
  final String? error;
  const TileResponseMessage({
    required this.requestId,
    required this.bytes,
    required this.isRgba,
    this.error,
  });
}

/// Sent from main to a worker: finish up and let the isolate terminate.
class CloseWorkerMessage {
  const CloseWorkerMessage();
}
