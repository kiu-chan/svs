import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/errors.dart';
import 'package:svs/src/tiff/compression/packbits_decoder.dart';

void main() {
  test('decodes literal runs, repeat runs, and a no-op control byte', () {
    // Literal run "hello" (n=4 -> 5 bytes), repeat run "XXX" (n=-2 -> 3x
    // next byte), a no-op (-128, skipped), then a 1-byte literal run "Z".
    final data = Uint8List.fromList([
      0x04, 0x68, 0x65, 0x6C, 0x6C, 0x6F, // 4, "hello"
      0xFE, 0x58, // -2, 'X'
      0x80, // no-op
      0x00, 0x5A, // 0, "Z"
    ]);
    expect(decodePackBits(data, 9), 'helloXXXZ'.codeUnits);
  });

  test('throws when the stream decodes to fewer bytes than expected', () {
    final data = Uint8List.fromList([0x00, 0x5A]); // just "Z"
    expect(() => decodePackBits(data, 5), throwsA(isA<SvsFormatException>()));
  });
}
