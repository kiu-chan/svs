import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/errors.dart';
import 'package:svs/src/tiff/compression/lzw_decoder.dart';

/// Packs a sequence of fixed-9-bit codes MSB-first — independent of, and
/// much simpler than, [decodeTiffLzw]'s variable-width dictionary logic, so
/// it's safe to hand-verify as test input rather than risking a shared bug
/// between "encoder" and decoder. Every code used below stays well under
/// 511, so the 9-bit width never needs to change.
Uint8List _packMsb9(List<int> codes) {
  var bitBuffer = 0;
  var bitCount = 0;
  final bytes = <int>[];
  for (final code in codes) {
    bitBuffer = (bitBuffer << 9) | code;
    bitCount += 9;
    while (bitCount >= 8) {
      bitCount -= 8;
      bytes.add((bitBuffer >> bitCount) & 0xFF);
    }
  }
  if (bitCount > 0) {
    bytes.add((bitBuffer << (8 - bitCount)) & 0xFF);
  }
  return Uint8List.fromList(bytes);
}

void main() {
  test('decodes plain literal codes (0-255 map directly to their byte)', () {
    final data = _packMsb9([256, 0x41, 0x42, 257]); // Clear, 'A', 'B', EOI
    expect(decodeTiffLzw(data, 2), [0x41, 0x42]);
  });

  test('grows the dictionary and reads back a multi-byte entry', () {
    // Clear, 'A', 'A' (adds "AA" at code 258), 258 ("AA" again), EOI.
    final data = _packMsb9([256, 0x41, 0x41, 258, 257]);
    expect(decodeTiffLzw(data, 4), [0x41, 0x41, 0x41, 0x41]); // "A"+"A"+"AA"
  });

  test('handles the KwKwK case: a code referencing an entry not yet added', () {
    // Clear, 'A', then immediately code 258 — which only becomes valid
    // *because* processing code 65 is about to define it. The classic
    // self-referencing edge case that trips up naive LZW decoders.
    final data = _packMsb9([256, 0x41, 258, 257]);
    expect(decodeTiffLzw(data, 3), [0x41, 0x41, 0x41]); // "A"+"AA"
  });

  test('truncates trailing bytes beyond expectedLength', () {
    final data = _packMsb9([256, 0x41, 0x42, 0x43, 257]);
    expect(decodeTiffLzw(data, 2), [0x41, 0x42]);
  });

  test('throws when the stream decodes to fewer bytes than expected', () {
    final data = _packMsb9([256, 0x41, 257]);
    expect(() => decodeTiffLzw(data, 5), throwsA(isA<SvsFormatException>()));
  });

  test('throws on a code that is neither a known entry nor a valid self-reference', () {
    final data = _packMsb9([256, 300, 257]);
    expect(() => decodeTiffLzw(data, 10), throwsA(isA<SvsFormatException>()));
  });
}
