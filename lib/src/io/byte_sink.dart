import 'dart:typed_data';

/// A random-access sink of bytes: sequential writes at a movable cursor,
/// with the ability to seek back and overwrite already-written bytes (used
/// to backpatch a TIFF header's offset/byte-count fields once their real
/// values are known — see `svs_pyramid_export_core.dart`). Mirrors
/// `byte_source.dart`'s read-side abstraction. [MemoryByteSink] is the only
/// implementation that needs to be platform-neutral (used by every
/// byte-returning export function on every platform); a `dart:io`
/// `RandomAccessFile`-backed implementation lives natively alongside the
/// `*ToFile` export functions that need it.
abstract class RandomAccessByteSink {
  /// Writes [bytes] starting at the current position, advancing it by
  /// `bytes.length`.
  Future<void> writeFrom(List<int> bytes);

  /// Moves the write cursor to [position], without writing anything.
  Future<void> setPosition(int position);

  /// The current write cursor position.
  Future<int> position();

  /// Releases any underlying resource (a file handle; a no-op for
  /// [MemoryByteSink]).
  Future<void> close();
}

/// A [RandomAccessByteSink] backed by an in-memory, growable buffer —
/// supports the same seek-and-overwrite pattern a real file does, without
/// needing a filesystem.
class MemoryByteSink implements RandomAccessByteSink {
  Uint8List _buffer = Uint8List(0);
  int _length = 0;
  int _position = 0;

  void _ensureCapacity(int minLength) {
    if (_buffer.length >= minLength) return;
    var newCapacity = _buffer.isEmpty ? 64 * 1024 : _buffer.length * 2;
    while (newCapacity < minLength) {
      newCapacity *= 2;
    }
    final grown = Uint8List(newCapacity);
    grown.setRange(0, _length, _buffer);
    _buffer = grown;
  }

  @override
  Future<void> writeFrom(List<int> bytes) async {
    final end = _position + bytes.length;
    _ensureCapacity(end);
    _buffer.setRange(_position, end, bytes);
    _position = end;
    if (_length < end) _length = end;
  }

  @override
  Future<void> setPosition(int position) async {
    _position = position;
  }

  @override
  Future<int> position() async => _position;

  @override
  Future<void> close() async {}

  /// The bytes written so far, from offset 0 up to the highest offset any
  /// write has reached — not just [position], since [setPosition] can move
  /// the cursor backwards to backpatch earlier bytes.
  Uint8List toBytes() => Uint8List.sublistView(_buffer, 0, _length);
}
