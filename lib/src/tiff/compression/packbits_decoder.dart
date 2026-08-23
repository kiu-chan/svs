import 'dart:typed_data';

import '../../errors.dart';

/// Decodes a TIFF `Compression=32773` (PackBits) byte stream — a simple
/// byte-oriented run-length encoding (TIFF6 spec section 9): each control
/// byte, read as signed, is either a literal-run length (`0..127` → copy
/// `n+1` following bytes), a repeat-run length (`-1..-127` → repeat the
/// next single byte `1-n` times), or a no-op (`-128`).
///
/// [expectedLength] is the known-good decompressed size, used both to size
/// the output and as a sanity check against a corrupt stream.
Uint8List decodePackBits(Uint8List data, int expectedLength) {
  final out = Uint8List(expectedLength);
  var outPos = 0;
  var pos = 0;

  while (pos < data.length && outPos < expectedLength) {
    final n = data[pos++].toSigned(8);
    if (n >= 0) {
      var count = n + 1;
      if (outPos + count > expectedLength) count = expectedLength - outPos;
      out.setRange(outPos, outPos + count, data, pos);
      pos += count;
      outPos += count;
    } else if (n != -128) {
      var count = 1 - n;
      if (pos >= data.length) break;
      final byte = data[pos++];
      if (outPos + count > expectedLength) count = expectedLength - outPos;
      out.fillRange(outPos, outPos + count, byte);
      outPos += count;
    }
  }

  if (outPos != expectedLength) {
    throw SvsFormatException('Corrupt PackBits stream: decoded $outPos bytes, expected $expectedLength');
  }
  return out;
}
