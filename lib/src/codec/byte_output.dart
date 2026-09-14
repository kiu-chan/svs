import 'dart:math' as math;
import 'dart:typed_data';

/// A growable byte buffer for encoders whose output size isn't known up
/// front.
class ByteOutput {
  Uint8List _bytes;
  int _length = 0;

  ByteOutput([int initialCapacity = 1024])
    : _bytes = Uint8List(math.max(16, initialCapacity));

  int get length => _length;

  void addByte(int byte) {
    if (_length == _bytes.length) _reserve(1);
    _bytes[_length++] = byte;
  }

  /// Appends `bytes[start..end)` (the whole list by default).
  void addBytes(List<int> bytes, [int start = 0, int? end]) {
    final count = (end ?? bytes.length) - start;
    _reserve(count);
    _bytes.setRange(_length, _length + count, bytes, start);
    _length += count;
  }

  void addUint32Be(int value) {
    addByte((value >> 24) & 0xff);
    addByte((value >> 16) & 0xff);
    addByte((value >> 8) & 0xff);
    addByte(value & 0xff);
  }

  void addUint32Le(int value) {
    addByte(value & 0xff);
    addByte((value >> 8) & 0xff);
    addByte((value >> 16) & 0xff);
    addByte((value >> 24) & 0xff);
  }

  /// A trimmed copy of everything written so far.
  Uint8List toBytes() => _bytes.sublist(0, _length);

  void _reserve(int count) {
    if (_length + count <= _bytes.length) return;
    final grown = Uint8List(math.max(_bytes.length * 2, _length + count));
    grown.setRange(0, _length, _bytes);
    _bytes = grown;
  }
}
