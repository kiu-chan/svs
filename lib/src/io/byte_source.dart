import 'dart:typed_data';

/// A random-access source of bytes: read an arbitrary `[offset, offset +
/// length)` range without needing the whole source in hand up front.
/// [TiffFile] is built entirely on top of this — [file_byte_source.dart]'s
/// `openFileByteSource` backs it with a real file on native platforms;
/// [MemoryByteSource] backs it with an in-memory buffer (the only option on
/// the web, where there's no filesystem, but also useful natively for bytes
/// that already came from somewhere else, e.g. a network fetch).
abstract class RandomAccessByteSource {
  /// Reads up to [length] bytes starting at [offset]. Best-effort at the end
  /// of the source: returns fewer bytes (down to empty) rather than padding
  /// or throwing — callers that need an exact length (see `TiffFile.readBytes`)
  /// check the returned length themselves and raise their own format error.
  Future<Uint8List> readRange(int offset, int length);

  /// Releases any underlying resource (a file handle; a no-op for
  /// [MemoryByteSource]).
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
