import 'dart:js_interop';
import 'dart:typed_data';

import 'byte_sink.dart';

/// Just the part of the DOM `FileSystemWritableFileStream` interface this
/// file needs, so the package doesn't depend on `package:web` for it.
extension type _WritableFileStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(_WriteParams params);
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> abort();
}

extension type _WriteParams._(JSObject _) implements JSObject {
  external factory _WriteParams({String type, int position, JSUint8Array data});
}

/// A [RandomAccessByteSink] that writes to a browser file through a
/// `FileSystemWritableFileStream`, so an export streamed into it with e.g.
/// `exportSvsRegionAsSvsToSink` goes to disk instead of memory, however
/// large the output.
///
/// Get the stream from a `FileSystemFileHandle`'s `createWritable()`: a
/// handle from `showSaveFilePicker()` (Chromium browsers) writes a file the
/// user chose, one from the origin private file system
/// (`navigator.storage.getDirectory()`, every current browser) a file the
/// app can then hand to the user as a download. The browser writes to a
/// temporary file and only replaces the target on [close], so call [abort]
/// instead if the export fails.
///
/// ```dart
/// import 'dart:js_interop';
///
/// import 'package:svs/svs.dart';
/// import 'package:svs/svs_web.dart';
/// import 'package:web/web.dart' as web;
///
/// Future<void> exportTo(web.FileSystemFileHandle handle, SvsFile svs) async {
///   final sink = FileSystemWritableByteSink(
///     await handle.createWritable().toDart,
///   );
///   try {
///     await rebuildSvsPyramidToSink(svs, sink: sink);
///   } catch (_) {
///     await sink.abort();
///     rethrow;
///   }
///   await sink.close();
/// }
/// ```
///
/// Contiguous writes are coalesced into chunks of up to 4 MB before they
/// reach the stream, so a pyramid's many small tile writes cost a few large
/// ones.
class FileSystemWritableByteSink implements RandomAccessByteSink {
  static const _chunkSize = 4 * 1024 * 1024;

  final _WritableFileStream _stream;
  final _chunk = Uint8List(_chunkSize);

  /// File offset of `_chunk[0]`, and how many bytes of it are pending.
  int _chunkStart = 0;
  int _chunkLength = 0;

  int _position = 0;
  bool _done = false;

  /// Wraps [writableFileStream], which must be a JS
  /// `FileSystemWritableFileStream` — throws [ArgumentError] otherwise.
  /// Takes a plain [JSObject] so any binding works, e.g. `package:web`'s.
  FileSystemWritableByteSink(JSObject writableFileStream)
    : _stream = _WritableFileStream._(writableFileStream) {
    if (!writableFileStream.instanceOfString('FileSystemWritableFileStream')) {
      throw ArgumentError.value(
        writableFileStream,
        'writableFileStream',
        'is not a FileSystemWritableFileStream',
      );
    }
  }

  @override
  Future<void> writeFrom(List<int> bytes) async {
    _checkOpen();
    if (bytes.isEmpty) return;
    if (_chunkLength > 0 && _position != _chunkStart + _chunkLength) {
      await _flush();
    }
    if (_chunkLength + bytes.length > _chunkSize) await _flush();
    if (bytes.length >= _chunkSize) {
      await _write(
        _position,
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );
    } else {
      if (_chunkLength == 0) _chunkStart = _position;
      _chunk.setRange(_chunkLength, _chunkLength + bytes.length, bytes);
      _chunkLength += bytes.length;
    }
    _position += bytes.length;
  }

  @override
  Future<void> setPosition(int position) async {
    _checkOpen();
    _position = position;
  }

  @override
  Future<int> position() async => _position;

  /// Writes out anything still pending and closes the stream, which is what
  /// replaces the target file with everything written. Idempotent.
  @override
  Future<void> close() async {
    if (_done) return;
    await _flush();
    _done = true;
    await _stream.close().toDart;
  }

  /// Closes the stream without committing: the target file is left as it
  /// was before this sink was created. Does nothing after [close].
  Future<void> abort() async {
    if (_done) return;
    _done = true;
    _chunkLength = 0;
    await _stream.abort().toDart;
  }

  Future<void> _flush() async {
    if (_chunkLength == 0) return;
    // `write` resolves once the stream has taken the bytes, so the chunk
    // buffer is free to reuse afterwards.
    await _write(_chunkStart, Uint8List.sublistView(_chunk, 0, _chunkLength));
    _chunkLength = 0;
  }

  Future<void> _write(int position, Uint8List data) => _stream
      .write(_WriteParams(type: 'write', position: position, data: data.toJS))
      .toDart;

  void _checkOpen() {
    if (_done) throw StateError('FileSystemWritableByteSink is closed');
  }
}
