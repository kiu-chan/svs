import 'dart:async';
import 'dart:isolate';

import '../errors.dart';
import '../svs/svs_file.dart';
import 'tile_messages.dart';
import 'tile_worker_types.dart';

/// Fetches and (for JPEG2000) decodes pyramid tiles on background isolates,
/// keeping the file I/O and JP2K wavelet decode off the UI thread.
///
/// JPEG tiles still need a final `dart:ui` decode on the main isolate after
/// [requestTile] returns (`dart:ui`'s image codec APIs only work there —
/// see flutter/flutter#109701) — this pool only offloads the splice/read,
/// which is still the part that can block on slow disk or network storage.
///
/// Two workers by default, statically routed by [TilePriority]: on-screen
/// ("visible") tiles never queue behind prefetch-margin ones.
class TileWorkerPool {
  final List<_Worker> _workers;
  final _pending = <int, Completer<TileWorkerResult>>{};
  int _nextRequestId = 0;

  TileWorkerPool._(this._workers) {
    for (final worker in _workers) {
      worker.responses.listen(_handleResponse);
    }
  }

  static Future<TileWorkerPool> spawn(
    String path, {
    int workerCount = 2,
  }) async {
    final workers = <_Worker>[];
    try {
      for (var i = 0; i < workerCount; i++) {
        workers.add(await _Worker.spawn(path));
      }
    } catch (_) {
      for (final worker in workers) {
        worker.dispose();
      }
      rethrow;
    }
    return TileWorkerPool._(workers);
  }

  TileRequestHandle requestTile({
    required int level,
    required int tileX,
    required int tileY,
    TilePriority priority = TilePriority.visible,
  }) {
    final requestId = _nextRequestId++;
    final completer = Completer<TileWorkerResult>();
    _pending[requestId] = completer;
    final workerIndex = priority == TilePriority.visible
        ? 0
        : _workers.length - 1;
    _workers[workerIndex].send(
      TileRequestMessage(
        requestId: requestId,
        level: level,
        tileX: tileX,
        tileY: tileY,
      ),
    );
    return TileRequestHandle(requestId: requestId, result: completer.future);
  }

  /// Rejects [TileRequestHandle.result] with [TileRequestCancelledException]
  /// right away, so the caller can clean up immediately rather than the
  /// request just hanging forever. Also tells the worker not to bother
  /// starting it — best-effort: if it already started, the worker finishes
  /// it anyway and the result is simply dropped when it comes back (no
  /// pending completer left for it to resolve).
  void cancel(int requestId) {
    final completer = _pending.remove(requestId);
    if (completer == null) return;
    completer.completeError(const TileRequestCancelledException());
    for (final worker in _workers) {
      worker.send(CancelTileMessage(requestId));
    }
  }

  void _handleResponse(TileResponseMessage message) {
    final completer = _pending.remove(message.requestId);
    if (completer == null) return; // cancelled, or a duplicate — ignore
    if (message.error != null) {
      completer.completeError(TileIoException(-1, -1, -1, message.error!));
    } else {
      completer.complete(
        TileWorkerResult(bytes: message.bytes, isRgba: message.isRgba),
      );
    }
  }

  Future<void> dispose() async {
    for (final worker in _workers) {
      worker.dispose();
    }
  }
}

class _Worker {
  final SendPort _sendPort;
  final ReceivePort _receivePort;
  final _responseController = StreamController<TileResponseMessage>.broadcast();

  Stream<TileResponseMessage> get responses => _responseController.stream;

  _Worker._(this._sendPort, this._receivePort);

  static Future<_Worker> spawn(String path) async {
    final mainReceivePort = ReceivePort();
    final readyCompleter = Completer<SendPort>();
    final openCompleter = Completer<void>();
    late final _Worker worker;

    mainReceivePort.listen((message) {
      if (!readyCompleter.isCompleted && message is SendPort) {
        readyCompleter.complete(message);
      } else if (!openCompleter.isCompleted && message is FileOpenedMessage) {
        if (message.ok) {
          openCompleter.complete();
        } else {
          openCompleter.completeError(
            SvsFormatException(message.error ?? 'worker failed to open file'),
          );
        }
      } else if (message is TileResponseMessage) {
        worker._responseController.add(message);
      }
    });

    await Isolate.spawn(
      _workerMain,
      mainReceivePort.sendPort,
      debugName: 'svs-tile-worker',
    );
    final workerSendPort = await readyCompleter.future;
    worker = _Worker._(workerSendPort, mainReceivePort);
    workerSendPort.send(OpenFileMessage(path));
    await openCompleter.future;
    return worker;
  }

  void send(Object message) => _sendPort.send(message);

  void dispose() {
    _sendPort.send(const CloseWorkerMessage());
    _receivePort.close();
    unawaited(_responseController.close());
  }
}

void _workerMain(SendPort mainSendPort) async {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  SvsFile? svsFile;
  final cancelled = <int>{};

  await for (final message in receivePort) {
    if (message is OpenFileMessage) {
      try {
        svsFile = await SvsFile.open(message.path);
        mainSendPort.send(const FileOpenedMessage(ok: true));
      } catch (e) {
        mainSendPort.send(FileOpenedMessage(ok: false, error: e.toString()));
      }
    } else if (message is TileRequestMessage) {
      if (cancelled.remove(message.requestId)) continue;
      final file = svsFile;
      if (file == null) continue;
      try {
        final level = file.levels[message.level];
        if (level.isJpeg) {
          final bytes = await level.readTileJpegBytes(
            message.tileX,
            message.tileY,
          );
          mainSendPort.send(
            TileResponseMessage(
              requestId: message.requestId,
              bytes: bytes.isEmpty ? null : bytes,
              isRgba: false,
            ),
          );
        } else {
          final rgba = await level.readTileRgba(message.tileX, message.tileY);
          mainSendPort.send(
            TileResponseMessage(
              requestId: message.requestId,
              bytes: rgba.isEmpty ? null : rgba,
              isRgba: true,
            ),
          );
        }
      } catch (e) {
        mainSendPort.send(
          TileResponseMessage(
            requestId: message.requestId,
            bytes: null,
            isRgba: false,
            error: e.toString(),
          ),
        );
      }
    } else if (message is CancelTileMessage) {
      cancelled.add(message.requestId);
    } else if (message is CloseWorkerMessage) {
      await svsFile?.close();
      receivePort.close();
    }
  }
}
