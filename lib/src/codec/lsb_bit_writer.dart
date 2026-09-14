import 'dart:typed_data';

import 'byte_output.dart';

/// Packs bit fields least-significant-bit first — the order both deflate
/// (RFC 1951) and WebP lossless (VP8L) use — into a [ByteOutput].
class LsbBitWriter {
  final ByteOutput _out;
  int _buffer = 0;
  int _count = 0;

  LsbBitWriter(this._out);

  /// Appends the low [count] bits of [value]. [count] is at most 24, which
  /// keeps the pending buffer within 31 bits — exact on the web too, where
  /// bitwise operators work on 32-bit values.
  void writeBits(int value, int count) {
    assert(count >= 0 && count <= 24);
    _buffer |= (value & ((1 << count) - 1)) << _count;
    _count += count;
    while (_count >= 8) {
      _out.addByte(_buffer & 0xff);
      _buffer >>= 8;
      _count -= 8;
    }
  }

  /// Pads with zero bits up to the next byte boundary.
  void alignToByte() {
    if (_count > 0) writeBits(0, 8 - _count);
  }

  /// Appends `bytes[start..end)` verbatim. The writer must be byte-aligned.
  void writeAlignedBytes(Uint8List bytes, int start, int end) {
    assert(_count == 0);
    _out.addBytes(bytes, start, end);
  }
}
