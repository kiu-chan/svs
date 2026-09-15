import 'dart:typed_data';

import '../errors.dart';
import '../svs/svs_file.dart';

/// Which queue a tile request goes to — see `TileWorkerPool`.
enum TilePriority { visible, prefetch }

/// A decoded (or decode-ready) tile from a `TileWorkerPool` request.
///
/// [bytes] is standalone JPEG bytes needing a `dart:ui` decode on the main
/// isolate when [isRgba] is false, or already-decoded tightly-packed
/// RGBA8888 bytes when [isRgba] is true. Null [bytes] means a sparse
/// (blank) tile.
///
/// [reduction] is the reduced-resolution shift RGBA [bytes] were decoded at
/// (see `TileResponseMessage.reduction`); always 0 for JPEG bytes.
class TileWorkerResult {
  final Uint8List? bytes;
  final bool isRgba;
  final int reduction;
  const TileWorkerResult({
    required this.bytes,
    required this.isRgba,
    this.reduction = 0,
  });
}

/// A tile fetch in flight: [requestId] is returned synchronously so the
/// caller can `TileWorkerPool.cancel` it later (e.g. once the tile scrolls
/// out of view) without waiting on [result] first.
class TileRequestHandle {
  final int requestId;
  final Future<TileWorkerResult> result;
  const TileRequestHandle({required this.requestId, required this.result});
}

/// Reads tile ([tx], [ty]) of [level] the way a `TileWorkerPool` worker
/// serves it — spliced JPEG bytes, or JPEG2000 decoded to RGBA at
/// `1 / 2^reduction` resolution — shared with `LodController`'s
/// calling-isolate fallback for when no pool is available.
///
/// A JPEG2000 codestream with fewer wavelet levels than [reduction] asks to
/// discard can't be decoded that small; it's decoded at full resolution
/// instead, reported via [TileWorkerResult.reduction].
Future<TileWorkerResult> fetchTile(
  SvsLevel level,
  int tx,
  int ty, {
  int reduction = 0,
}) async {
  if (level.isJpeg) {
    final bytes = await level.readTileJpegBytes(tx, ty);
    return TileWorkerResult(bytes: bytes.isEmpty ? null : bytes, isRgba: false);
  }
  if (reduction > 0) {
    try {
      final rgba = await level.readTileRgba(
        tx,
        ty,
        reducedResolutionFactor: reduction,
      );
      return TileWorkerResult(
        bytes: rgba.isEmpty ? null : rgba,
        isRgba: true,
        reduction: reduction,
      );
    } on TileIoException {
      // Retried at full resolution below.
    }
  }
  final rgba = await level.readTileRgba(tx, ty);
  return TileWorkerResult(bytes: rgba.isEmpty ? null : rgba, isRgba: true);
}

/// Thrown to reject [TileRequestHandle.result] when `TileWorkerPool.cancel`
/// is called for that request.
class TileRequestCancelledException implements Exception {
  const TileRequestCancelledException();
  @override
  String toString() => 'TileRequestCancelledException';
}
