import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
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
/// [defaultWorkerCount] workers unless told otherwise. Prefetch-margin tiles
/// all go to the last worker, and on-screen ("visible") tiles to whichever
/// of the others has the fewest outstanding requests — so on-screen tiles
/// never queue behind prefetch ones.
class TileWorkerPool {
  /// Half the machine's cores, clamped to 2-4: enough to decode a JPEG2000
  /// slide briskly, while always leaving cores free for the UI and raster
  /// threads (and every other app on the machine) — an unbounded pool would
  /// just trade UI jank for whole-system slowdown.
  static int get defaultWorkerCount =>
      (Platform.numberOfProcessors ~/ 2).clamp(2, 4);

  final List<_Worker> _workers;
  final List<int> _outstanding;
  final _pending = <int, (Completer<TileWorkerResult>, int)>{};
  int _nextRequestId = 0;

  TileWorkerPool._(this._workers)
    : _outstanding = List.filled(_workers.length, 0) {
    for (final worker in _workers) {
      worker.responses.listen(_handleResponse);
    }
  }

  /// How many background isolates this pool runs.
  int get workerCount => _workers.length;

  static Future<TileWorkerPool> spawn(String path, {int? workerCount}) async {
    final count = workerCount ?? defaultWorkerCount;
    Object? error;
    StackTrace? stackTrace;
    final workers = await Future.wait([
      for (var i = 0; i < count; i++)
        _Worker.spawn(path).then<_Worker?>(
          (worker) => worker,
          onError: (Object e, StackTrace s) {
            error ??= e;
            stackTrace ??= s;
            return null;
          },
        ),
    ]);
    if (error != null) {
      for (final worker in workers) {
        worker?.dispose();
      }
      Error.throwWithStackTrace(error!, stackTrace!);
    }
    return TileWorkerPool._([for (final worker in workers) worker!]);
  }

  /// [reduction] asks for a JPEG2000 tile to be decoded at `1 / 2^reduction`
  /// of its stored resolution (see `selectReduction`) — the result's
  /// [TileWorkerResult.reduction] says what it was actually decoded at.
  /// Ignored for JPEG tiles.
  TileRequestHandle requestTile({
    required int level,
    required int tileX,
    required int tileY,
    TilePriority priority = TilePriority.visible,
    int reduction = 0,
  }) {
    final requestId = _nextRequestId++;
    final completer = Completer<TileWorkerResult>();
    final workerIndex = _pickWorker(priority);
    _pending[requestId] = (completer, workerIndex);
    _outstanding[workerIndex]++;
    _workers[workerIndex].send(
      TileRequestMessage(
        requestId: requestId,
        level: level,
        tileX: tileX,
        tileY: tileY,
        reduction: reduction,
      ),
    );
    return TileRequestHandle(requestId: requestId, result: completer.future);
  }

  int _pickWorker(TilePriority priority) {
    final last = _workers.length - 1;
    if (priority == TilePriority.prefetch || last == 0) return last;
    var best = 0;
    for (var i = 1; i < last; i++) {
      if (_outstanding[i] < _outstanding[best]) best = i;
    }
    return best;
  }

  /// Rejects [TileRequestHandle.result] with [TileRequestCancelledException]
  /// right away, so the caller can clean up immediately rather than the
  /// request just hanging forever. Also drops it from its worker's queue if
  /// the worker hasn't started it yet — one already being fetched or decoded
  /// runs to completion, and its result is simply discarded when it comes
  /// back (no pending completer left for it to resolve).
  void cancel(int requestId) {
    final pending = _pending.remove(requestId);
    if (pending == null) return;
    final (completer, workerIndex) = pending;
    _outstanding[workerIndex]--;
    completer.completeError(const TileRequestCancelledException());
    _workers[workerIndex].send(CancelTileMessage(requestId));
  }

  void _handleResponse(TileResponseMessage message) {
    final pending = _pending.remove(message.requestId);
    if (pending == null) return; // cancelled, or a duplicate — ignore
    final (completer, workerIndex) = pending;
    _outstanding[workerIndex]--;
    if (message.error != null) {
      completer.completeError(TileIoException(-1, -1, -1, message.error!));
    } else {
      completer.complete(
        TileWorkerResult(
          bytes: message.bytes,
          isRgba: message.isRgba,
          reduction: message.reduction,
        ),
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

    try {
      await Isolate.spawn(
        _workerMain,
        mainReceivePort.sendPort,
        debugName: 'svs-tile-worker',
      );
      final workerSendPort = await readyCompleter.future;
      worker = _Worker._(workerSendPort, mainReceivePort);
      workerSendPort.send(OpenFileMessage(path));
      await openCompleter.future;
    } catch (_) {
      mainReceivePort.close();
      rethrow;
    }
    return worker;
  }

  void send(Object message) => _sendPort.send(message);

  void dispose() {
    _sendPort.send(const CloseWorkerMessage());
    _receivePort.close();
    unawaited(_responseController.close());
  }
}

/// Requests are queued locally rather than handled inside the port
/// listener itself, so a [CancelTileMessage] is seen as soon as the worker
/// yields (every tile read awaits file I/O) and can pull a request out of
/// the queue before it starts — handling each request inline, in arrival
/// order, would only ever see a cancel after the request it names had
/// already been fully served.
void _workerMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  SvsFile? svsFile;
  final queue = ListQueue<TileRequestMessage>();
  var draining = false;
  var closing = false;

  Future<void> shutDown() async {
    await svsFile?.close();
    receivePort.close();
  }

  Future<void> drain() async {
    draining = true;
    while (queue.isNotEmpty && !closing) {
      final request = queue.removeFirst();
      final file = svsFile;
      if (file == null) continue;
      mainSendPort.send(await _serveTile(file, request));
    }
    draining = false;
    if (closing) await shutDown();
  }

  receivePort.listen((message) async {
    if (message is OpenFileMessage) {
      try {
        svsFile = await SvsFile.open(message.path);
        mainSendPort.send(const FileOpenedMessage(ok: true));
      } catch (e) {
        mainSendPort.send(FileOpenedMessage(ok: false, error: e.toString()));
      }
    } else if (message is TileRequestMessage) {
      queue.add(message);
      if (!draining) unawaited(drain());
    } else if (message is CancelTileMessage) {
      queue.removeWhere((request) => request.requestId == message.requestId);
    } else if (message is CloseWorkerMessage) {
      closing = true;
      queue.clear();
      if (!draining) await shutDown();
    }
  });
}

Future<TileResponseMessage> _serveTile(
  SvsFile file,
  TileRequestMessage request,
) async {
  try {
    final result = await fetchTile(
      file.levels[request.level],
      request.tileX,
      request.tileY,
      reduction: request.reduction,
    );
    return TileResponseMessage(
      requestId: request.requestId,
      bytes: result.bytes,
      isRgba: result.isRgba,
      reduction: result.reduction,
    );
  } catch (e) {
    return TileResponseMessage(
      requestId: request.requestId,
      bytes: null,
      isRgba: false,
      error: e.toString(),
    );
  }
}
