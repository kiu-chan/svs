/// @docImport '../errors.dart';
/// @docImport '../svs/svs_file.dart';
library;

import 'dart:typed_data';

/// A random-access source of a slide's bytes: reads an arbitrary `[offset,
/// offset + length)` range without needing the whole file in hand up front.
///
/// Pass one to [SvsFile.openSource] to open a slide from wherever its bytes
/// live — only the ranges actually needed (the TIFF directories, then each
/// tile as it's viewed) are ever read, so even a multi-GB slide never has to
/// fit in memory. `package:svs/svs_web.dart`'s `BlobByteSource` reads a
/// browser `File`/`Blob` this way; implement this class yourself for any
/// other storage (e.g. HTTP `Range` requests against a server).
///
/// Implementations must cope with several [readRange] calls in flight at
/// once (tiles are requested concurrently while panning), serializing them
/// internally if the underlying storage needs that.
abstract class RandomAccessByteSource {
  /// Allows subclasses to declare a const constructor of their own.
  const RandomAccessByteSource();

  /// Reads up to [length] bytes starting at [offset]. Best-effort at the end
  /// of the source: returns fewer bytes (down to empty) rather than padding
  /// or throwing. The reader checks the length it gets back itself, and
  /// reports a truncated file as an [SvsFormatException].
  Future<Uint8List> readRange(int offset, int length);

  /// Releases any underlying resource, e.g. a file handle. Called once by
  /// [SvsFile.close], or by [SvsFile.openSource] if the slide fails to open.
  Future<void> close();
}

/// A [RandomAccessByteSource] backed by an in-memory buffer already fully in
/// hand — no serialization needed between reads since there's no shared
/// cursor to race on.
class MemoryByteSource implements RandomAccessByteSource {
  final Uint8List _bytes;

  MemoryByteSource(this._bytes);

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    if (offset < 0 || length <= 0 || offset >= _bytes.length) {
      return Uint8List(0);
    }
    final end = offset + length > _bytes.length
        ? _bytes.length
        : offset + length;
    return Uint8List.sublistView(_bytes, offset, end);
  }

  @override
  Future<void> close() async {}
}
