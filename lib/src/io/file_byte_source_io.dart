import 'dart:io';
import 'dart:typed_data';

import 'byte_source.dart';

Future<RandomAccessByteSource> openFileByteSource(String path) async {
  final raf = await File(path).open(mode: FileMode.read);
  return _FileByteSource(raf);
}

class _FileByteSource implements RandomAccessByteSource {
  final RandomAccessFile _raf;

  // Serializes access to `_raf`: `setPosition` then `read` is two separate
  // awaits on one shared file handle, so concurrent callers (e.g. many tiles
  // requested at once while panning/zooming) could otherwise interleave
  // their setPosition/read pairs and silently read each other's bytes at the
  // wrong offset. Every read is chained onto this to force one in flight at
  // a time.
  Future<void> _readQueue = Future.value();

  _FileByteSource(this._raf);

  @override
  Future<Uint8List> readRange(int offset, int length) {
    if (length <= 0) return Future.value(Uint8List(0));
    final result = _readQueue.then((_) => _readUnlocked(offset, length));
    // Keep the queue moving even if this read failed — swallow the error
    // here (it still propagates to the caller via `result`) so one bad read
    // doesn't wedge every read after it.
    _readQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Uint8List> _readUnlocked(int offset, int length) async {
    await _raf.setPosition(offset);
    return _raf.read(length);
  }

  @override
  Future<void> close() => _raf.close();
}
