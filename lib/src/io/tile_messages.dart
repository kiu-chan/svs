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
///
/// [reduction] asks for a JPEG2000 tile to be decoded at `1 / 2^reduction`
/// of its stored resolution (see `selectReduction`); ignored for JPEG
/// tiles, whose reduced decode happens on the main isolate instead.
class TileRequestMessage {
  final int requestId;
  final int level;
  final int tileX;
  final int tileY;
  final int reduction;
  const TileRequestMessage({
    required this.requestId,
    required this.level,
    required this.tileX,
    required this.tileY,
    this.reduction = 0,
  });
}

/// Sent from main to a worker: if [requestId] hasn't been started yet,
/// drop it from the worker's queue — a request already being fetched or
/// decoded still runs to completion (see `TileWorkerPool.cancel`).
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
///
/// [reduction] is the reduced-resolution shift the RGBA bytes were actually
/// decoded at — which can be lower than requested, if the codestream has
/// fewer wavelet levels than the request asked to discard.
class TileResponseMessage {
  final int requestId;
  final Uint8List? bytes;
  final bool isRgba;
  final int reduction;
  final String? error;
  const TileResponseMessage({
    required this.requestId,
    required this.bytes,
    required this.isRgba,
    this.reduction = 0,
    this.error,
  });
}

/// Sent from main to a worker: finish up and let the isolate terminate.
class CloseWorkerMessage {
  const CloseWorkerMessage();
}
