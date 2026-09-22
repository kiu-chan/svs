/// @docImport '../render/svs_pyramid_export.dart';
/// @docImport '../render/svs_pyramid_rebuild.dart';
library;

import 'dart:typed_data';

/// A random-access destination for an exported slide's bytes: sequential
/// writes at a movable cursor, plus seeking back to overwrite bytes already
/// written — a pyramid export writes its TIFF header first and fills in the
/// tile offsets once the tiles themselves are written.
///
/// Pass one to [exportSvsRegionAsSvsToSink],
/// [exportSvsRegionAsSvsPreservingLevelsToSink] or [rebuildSvsPyramidToSink]
/// to stream the output somewhere other than memory. On the web,
/// `package:svs/svs_web.dart`'s `FileSystemWritableByteSink` writes to a
/// file on disk this way; implement this class yourself for any other
/// destination.
abstract class RandomAccessByteSink {
  /// Writes [bytes] starting at the current position, advancing it by
  /// `bytes.length`.
  Future<void> writeFrom(List<int> bytes);

  /// Moves the write cursor to [position], without writing anything.
  Future<void> setPosition(int position);

  /// The current write cursor position.
  Future<int> position();

  /// Releases any underlying resource, e.g. a file handle. The `*ToSink`
  /// exports never call this: closing is up to whoever opened the sink.
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
