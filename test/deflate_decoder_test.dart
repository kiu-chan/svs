import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/tiff/compression/deflate_decoder.dart';

void main() {
  test('decodes a zlib-wrapped deflate stream (TIFF Deflate/AdobeDeflate convention)', () {
    final original = Uint8List.fromList(List.generate(2000, (i) => (i * 37) % 256));
    final compressed = Uint8List.fromList(ZLibEncoder().convert(original));

    expect(decodeTiffDeflate(compressed), original);
  });
}
