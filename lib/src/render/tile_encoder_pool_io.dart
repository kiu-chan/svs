import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../codec/rgba_image.dart';
import 'band_tile_encoder.dart';

/// The most background isolates one export uses. Tiles are still decoded on
/// the main isolate, so beyond a few encoders that — not encoding — is the
/// bottleneck.
const _maxWorkers = 4;

/// Encodes a pyramid export's tiles on a few long-lived background isolates.
///
/// Each band's tiles are split between the workers and encoded in parallel,
/// which keeps the work off the UI isolate and spreads it across cores.
/// [start] one per export and [close] it when the export ends.
class TileEncoderPool {
  final List<_Worker> _workers;

  TileEncoderPool._(this._workers);

  static Future<TileEncoderPool> start(TileEncoding encoding) async {
    final count = math.max(
      1,
      math.min(_maxWorkers, Platform.numberOfProcessors - 1),
    );
    final workers = await Future.wait([
      for (var i = 0; i < count; i++) _Worker.spawn(encoding),
    ], cleanUp: (worker) => worker.close());
    return TileEncoderPool._(workers);
  }

  /// Encodes every tile of a [width]x[height] band of RGBA [pixels], tiled
  /// at [tileWidth]x[tileLength], left to right. The pixels each worker
  /// needs are copied before this returns, so the caller may keep using
  /// [pixels] meanwhile.
  Future<List<Uint8List>> encodeBand(
    Uint8List pixels, {
    required int width,
    required int height,
    required int tileWidth,
    required int tileLength,
  }) async {
    final tileCount = (width + tileWidth - 1) ~/ tileWidth;
    final tilesPerWorker = (tileCount + _workers.length - 1) ~/ _workers.length;
    final chunks = <Future<List<Uint8List>>>[];
    var worker = 0;
    for (var first = 0; first < tileCount; first += tilesPerWorker) {
      final left = first * tileWidth;
      final right = math.min(width, (first + tilesPerWorker) * tileWidth);
      // One copy, straight into memory the worker takes over without
      // copying again.
      final columns = TransferableTypedData.fromList([
        for (var row = 0; row < height; row++)
          Uint8List.sublistView(
            pixels,
            (row * width + left) * 4,
            (row * width + right) * 4,
          ),
      ]);
      chunks.add(
        _workers[worker++].encode(
          columns,
          width: right - left,
          height: height,
          tileWidth: tileWidth,
          tileLength: tileLength,
        ),
      );
    }
    final encoded = await Future.wait(chunks);
    return [for (final chunk in encoded) ...chunk];
  }

  /// Shuts every worker down. Requests still in flight never complete.
  Future<void> close() async {
    for (final worker in _workers) {
      worker.close();
    }
  }
}

class _Worker {
  final _responses = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<List<Uint8List>>>{};
  Isolate? _isolate;
  late final SendPort _requests;
  var _nextId = 0;
  var _closed = false;

  _Worker._() {
    _responses.listen(_handle);
  }

  static Future<_Worker> spawn(TileEncoding encoding) async {
    final worker = _Worker._();
    try {
      worker._isolate = await Isolate.spawn(
        _workerMain,
        (worker._responses.sendPort, encoding),
        onError: worker._responses.sendPort,
        onExit: worker._responses.sendPort,
      );
      worker._requests = await worker._ready.future;
    } catch (_) {
      worker.close();
      rethrow;
    }
    return worker;
  }

  Future<List<Uint8List>> encode(
    TransferableTypedData pixels, {
    required int width,
    required int height,
    required int tileWidth,
    required int tileLength,
  }) {
    if (_closed) throw StateError('TileEncoderPool is closed');
    final id = _nextId++;
    final completer = Completer<List<Uint8List>>();
    _pending[id] = completer;
    _requests.send((id, pixels, width, height, tileWidth, tileLength));
    return completer.future;
  }

  void _handle(Object? message) {
    switch (message) {
      case SendPort requests:
        _ready.complete(requests);
      case (int id, List<Uint8List>? tiles, Object? error, String? stackTrace):
        final completer = _pending.remove(id);
        if (completer == null) return;
        if (error == null) {
          completer.complete(tiles!);
        } else {
          completer.completeError(
            error,
            stackTrace == null ? null : StackTrace.fromString(stackTrace),
          );
        }
      case [final error, final stackTrace]:
        // An uncaught error, which also ends the isolate.
        _fail(RemoteError('$error', '$stackTrace'));
      case null:
        // The isolate exited.
        _fail(StateError('A tile encoder isolate exited unexpectedly'));
    }
  }

  void _fail(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    close();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _responses.close();
    _pending.clear();
  }
}

void _workerMain((SendPort, TileEncoding) setup) {
  final (replyTo, encoding) = setup;
  final encoder = BandTileEncoder(encoding);
  final requests = ReceivePort();
  replyTo.send(requests.sendPort);
  requests.listen((message) {
    final (
      int id,
      TransferableTypedData pixels,
      int width,
      int height,
      int tileWidth,
      int tileLength,
    ) = message as (int, TransferableTypedData, int, int, int, int);
    try {
      final region = RgbaImage(
        width,
        height,
        pixels.materialize().asUint8List(),
      );
      final tiles = encoder.encode(
        region,
        tileWidth: tileWidth,
        tileLength: tileLength,
      );
      replyTo.send((id, tiles, null, null));
    } catch (error, stackTrace) {
      try {
        replyTo.send((id, null, error, '$stackTrace'));
      } catch (_) {
        // The error object itself can't cross isolates; send its text.
        replyTo.send((
          id,
          null,
          RemoteError('$error', '$stackTrace'),
          '$stackTrace',
        ));
      }
    }
  });
}
