import 'dart:js_interop';
import 'dart:typed_data';

import 'byte_source.dart';

/// Just the part of the DOM `Blob` interface this file needs, so the package
/// doesn't depend on `package:web` for it.
extension type _Blob._(JSObject _) implements JSObject {
  external int get size;
  external _Blob slice(int start, int end);
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

/// A [RandomAccessByteSource] that reads a browser `Blob` — usually a `File`
/// from an `<input type="file">` or a drop event — one slice at a time, so
/// a slide opened from it with `SvsFile.openSource` is never loaded into
/// memory whole, however large it is.
///
/// ```dart
/// import 'package:svs/svs.dart';
/// import 'package:svs/svs_web.dart';
/// import 'package:web/web.dart' as web;
///
/// Future<SvsFile> openPicked(web.File file) =>
///     SvsFile.openSource(BlobByteSource(file));
/// ```
class BlobByteSource implements RandomAccessByteSource {
  final _Blob _blob;

  /// Wraps [blob], which must be a JS `Blob` (a `File` is one) — throws
  /// [ArgumentError] otherwise. Takes a plain [JSObject] so any binding
  /// works, e.g. `package:web`'s `File`/`Blob`.
  BlobByteSource(JSObject blob) : _blob = _Blob._(blob) {
    if (!blob.instanceOfString('Blob')) {
      throw ArgumentError.value(blob, 'blob', 'is not a JS Blob or File');
    }
  }

  /// The blob's size in bytes.
  int get length => _blob.size;

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    final size = this.length;
    if (offset < 0 || length <= 0 || offset >= size) return Uint8List(0);
    final end = offset + length > size ? size : offset + length;
    final buffer = await _blob.slice(offset, end).arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  /// A no-op: a `Blob` holds no handle to release.
  @override
  Future<void> close() async {}
}
