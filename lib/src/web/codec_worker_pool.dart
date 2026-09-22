// The page side of the web codec worker (codec_worker_main.dart): a few
// Web Workers, started from the embedded script on first use, that decode
// and encode off the main thread. Web only.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'codec_worker_js.g.dart';
import 'codec_worker_protocol.dart';

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(String url);
  external set onmessage(JSFunction handler);
  external set onerror(JSFunction handler);
  external void postMessage(JSAny? message, JSArray<JSAny> transfer);
  external void terminate();
}

extension type _MessageEvent._(JSObject _) implements JSObject {
  external JSObject get data;
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts, JSObject options);
}

@JS('URL.createObjectURL')
external String _createObjectUrl(JSObject blob);

@JS('navigator.hardwareConcurrency')
external JSNumber? get _hardwareConcurrency;

/// Thrown when no worker could run a request: the page doesn't allow
/// `blob:` workers (a Content-Security-Policy without `worker-src blob:`),
/// or the worker failed. Callers do the work themselves instead.
class CodecWorkerUnavailable implements Exception {
  const CodecWorkerUnavailable();
}

/// The most workers the pool starts: past a few, the main thread handing
/// them tiles is the bottleneck.
const _maxWorkers = 4;

class _Slot {
  final _Worker worker;
  int inFlight = 0;

  _Slot(this.worker);
}

class CodecWorkerPool {
  CodecWorkerPool._();

  static final instance = CodecWorkerPool._();

  List<_Slot>? _slots;
  bool _failed = false;
  var _nextId = 0;
  final _pending = <int, (Completer<JSObject>, _Slot)>{};

  /// How many workers requests are spread across, starting them if need be
  /// — 0 if workers can't run on this page.
  int get size => _start()?.length ?? 0;

  List<_Slot>? _start() {
    if (_failed) return null;
    if (_slots != null) return _slots;
    try {
      final options = JSObject()..['type'] = 'text/javascript'.toJS;
      final url = _createObjectUrl(_Blob([codecWorkerJs.toJS].toJS, options));
      final cores = _hardwareConcurrency?.toDartInt ?? 2;
      final count = math.max(1, math.min(_maxWorkers, cores - 1));
      final slots = <_Slot>[];
      for (var i = 0; i < count; i++) {
        final slot = _Slot(_Worker(url));
        slot.worker.onmessage = ((_MessageEvent e) => _receive(e.data)).toJS;
        slot.worker.onerror = ((JSAny _) => _fail()).toJS;
        slots.add(slot);
      }
      return _slots = slots;
    } catch (_) {
      _fail();
      return null;
    }
  }

  /// Stops using workers for good: whatever went wrong would go wrong again.
  void _fail() {
    _failed = true;
    for (final slot in _slots ?? const <_Slot>[]) {
      slot.worker.terminate();
    }
    _slots = null;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final (completer, _) in pending) {
      completer.completeError(const CodecWorkerUnavailable());
    }
  }

  void _receive(JSObject reply) {
    final id = (reply[idField] as JSNumber).toDartInt;
    final entry = _pending.remove(id);
    if (entry == null) return;
    final (completer, slot) = entry;
    slot.inFlight--;
    completer.complete(reply);
  }

  /// Sends [request] to the least busy worker and returns its reply.
  /// [transfer] lists buffers handed over to the worker, which the caller
  /// must not touch again. Throws [CodecWorkerUnavailable] if workers can't
  /// run here.
  Future<JSObject> request(String op, JSObject request, List<JSAny> transfer) {
    final slots = _start();
    if (slots == null) return Future.error(const CodecWorkerUnavailable());
    var slot = slots.first;
    for (final s in slots) {
      if (s.inFlight < slot.inFlight) slot = s;
    }
    final id = _nextId++;
    final completer = Completer<JSObject>();
    _pending[id] = (completer, slot);
    slot.inFlight++;
    request[opField] = op.toJS;
    request[idField] = id.toJS;
    slot.worker.postMessage(request, transfer.toJS);
    return completer.future;
  }
}

/// A copy of [bytes] in its own buffer, ready to transfer to a worker.
///
/// Posting a view as-is would structured-clone the entire buffer behind it
/// — for a tile read out of a slide held in memory, the whole slide.
JSUint8Array transferableCopy(Uint8List bytes, List<JSAny> transfer) {
  final js = Uint8List.fromList(bytes).toJS;
  transfer.add(js['buffer']!);
  return js;
}
