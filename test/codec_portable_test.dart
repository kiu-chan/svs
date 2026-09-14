// Runs on the VM and on the web (`flutter test --platform chrome`). The web
// is where the pure-Dart zlib actually ships, and its bitwise operators have
// 32-bit semantics the VM doesn't, so this file avoids dart:io and dart:ui:
// reference zlib streams are embedded, and encoder output is decoded with
// package:image (pure Dart, a test-only dependency).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:svs/src/codec/bmp_encoder.dart';
import 'package:svs/src/codec/deflate.dart';
import 'package:svs/src/codec/inflate.dart';
import 'package:svs/src/codec/jpeg_encoder.dart';
import 'package:svs/src/codec/png_encoder.dart';
import 'package:svs/src/codec/rgba_image.dart';
import 'package:svs/src/codec/tiff_encoder.dart';
import 'package:svs/src/codec/webp_encoder.dart';
import 'package:svs/src/codec/zlib.dart';

/// A gradient over per-pixel noise, with varying alpha unless [opaque].
RgbaImage _testImage(int width, int height, {bool opaque = false}) {
  final random = math.Random(width * 131 + height);
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = (y * width + x) * 4;
      final noisy = y >= height ~/ 2;
      pixels[p] = noisy ? random.nextInt(256) : x * 255 ~/ math.max(1, width - 1);
      pixels[p + 1] = noisy ? random.nextInt(256) : 90;
      pixels[p + 2] = noisy ? random.nextInt(256) : y * 255 ~/ math.max(1, height - 1);
      pixels[p + 3] = opaque ? 255 : (x * 29 + y * 13) & 0xff;
    }
  }
  return RgbaImage(width, height, pixels);
}

Uint8List _rgbaOf(img.Image decoded) =>
    (decoded.numChannels == 4
            ? decoded
            : decoded.convert(numChannels: 4, alpha: 255))
        .getBytes(order: img.ChannelOrder.rgba);

void main() {
  group('inflateZlib decodes reference zlib streams', () {
    test('a stored block', () {
      expect(
        String.fromCharCodes(inflateZlib(_storedStream)),
        'stored deflate block',
      );
    });

    test('a fixed-Huffman block', () {
      expect(
        String.fromCharCodes(inflateZlib(_fixedStream)),
        'abcabcabcabc hello hello hello',
      );
    });

    test('a dynamic-Huffman block', () {
      final out = inflateZlib(_dynamicStream);
      expect(out.length, 906);
      expect(String.fromCharCodes(out.take(13)), 'pyramid the. ');
      final trailer = ByteData.sublistView(
        _dynamicStream,
        _dynamicStream.length - 4,
      ).getUint32(0);
      expect(adler32(out), trailer);
    });
  });

  test('deflateZlib and the platform zlib round-trip', () {
    final random = math.Random(5);
    for (final data in [
      Uint8List(0),
      Uint8List.fromList(List.generate(70000, (_) => random.nextInt(256))),
      Uint8List.fromList(
        List.generate(200000, (i) => (i ~/ 3000) % 5 + (i % 7 == 0 ? 1 : 0)),
      ),
    ]) {
      expect(inflateZlib(deflateZlib(data)), data);
      expect(zlibDecode(zlibEncode(data)), data);
    }
  });

  for (final (width, height) in [(1, 1), (37, 23), (130, 70)]) {
    final size = '${width}x$height';

    test('lossless encoders round-trip $size exactly', () {
      final image = _testImage(width, height);
      expect(_rgbaOf(img.decodePng(encodePng(image))!), image.pixels);
      expect(_rgbaOf(img.decodeWebP(encodeWebP(image))!), image.pixels);
      expect(_rgbaOf(img.decodeTiff(encodeTiff(image))!), image.pixels);
      final opaque = _testImage(width, height, opaque: true);
      expect(_rgbaOf(img.decodeBmp(encodeBmp(opaque))!), opaque.pixels);
    });

    test('JPEG $size decodes to the right size', () {
      final image = _testImage(width, height, opaque: true);
      final decoded = img.decodeJpg(JpegEncoder(quality: 90).encode(image))!;
      expect((decoded.width, decoded.height), (width, height));
    });
  }
}

/// `zlib.compress(b'stored deflate block', 0)`.
final _storedStream = Uint8List.fromList([
  0x78, 0x01, 0x01, 0x14, 0x00, 0xeb, 0xff, 0x73, 0x74, 0x6f, 0x72, 0x65, //
  0x64, 0x20, 0x64, 0x65, 0x66, 0x6c, 0x61, 0x74, 0x65, 0x20, 0x62, 0x6c,
  0x6f, 0x63, 0x6b, 0x52, 0x06, 0x07, 0xb2,
]);

/// `zlib.compress(b'abcabcabcabc hello hello hello', 9)`.
final _fixedStream = Uint8List.fromList([
  0x78, 0xda, 0x4b, 0x4c, 0x4a, 0x4e, 0x84, 0x21, 0x85, 0x8c, 0xd4, 0x9c, //
  0x9c, 0x7c, 0x64, 0x12, 0x00, 0xac, 0xff, 0x0b, 0x35,
]);

/// Python's `zlib.compress(text, 9)` of 906 bytes of pseudo-random words
/// starting "pyramid the. ".
final _dynamicStream = Uint8List.fromList([
  0x78, 0xda, 0x7d, 0x53, 0x6d, 0x0e, 0x83, 0x30, 0x08, 0xbd, 0x4a, 0x4f, //
  0xd0, 0x3b, 0x39, 0x25, 0xb1, 0x09, 0x55, 0x63, 0x75, 0xc9, 0x76, 0xfa,
  0x29, 0x14, 0x28, 0xba, 0xed, 0x0f, 0xa6, 0xf0, 0x78, 0x3c, 0x3e, 0x5c,
  0x5e, 0x6b, 0x97, 0xd3, 0x10, 0xb6, 0x11, 0x62, 0x58, 0xec, 0x11, 0xb6,
  0x84, 0xa0, 0x8e, 0x36, 0x90, 0x21, 0x3f, 0xd6, 0x6e, 0xb2, 0x60, 0xd9,
  0xba, 0x34, 0x85, 0x1e, 0x10, 0x43, 0xc1, 0x34, 0x00, 0xa1, 0xd8, 0xa9,
  0x58, 0x62, 0x7b, 0xcf, 0x73, 0x36, 0x17, 0x23, 0x94, 0xf9, 0x00, 0xc4,
  0x80, 0xf0, 0x04, 0x64, 0x30, 0x53, 0x9d, 0x29, 0xf1, 0x70, 0x94, 0xb2,
  0x33, 0xaf, 0xe0, 0x05, 0x49, 0x01, 0x7e, 0x48, 0x88, 0xca, 0xd4, 0x87,
  0x50, 0x92, 0x8f, 0x4c, 0x4d, 0x21, 0xb9, 0xd3, 0xde, 0x23, 0xec, 0xa5,
  0x8d, 0x8e, 0xd0, 0x8a, 0x38, 0x51, 0xd1, 0x69, 0x14, 0x43, 0x24, 0x92,
  0xcf, 0xad, 0x58, 0xf3, 0x8e, 0x97, 0xe8, 0xa2, 0x61, 0xb5, 0x2f, 0x75,
  0xa9, 0xd6, 0xb6, 0xe7, 0x1a, 0x8c, 0x97, 0xe6, 0x5c, 0x93, 0x5c, 0x57,
  0x68, 0xaa, 0x28, 0x26, 0xf1, 0xcb, 0x21, 0xd1, 0x3a, 0xf9, 0x4b, 0x5d,
  0x1d, 0x2f, 0x7f, 0xfe, 0x64, 0x8a, 0x98, 0xd6, 0xde, 0xce, 0xc1, 0x6d,
  0xe6, 0x3a, 0x28, 0xd2, 0xc6, 0xcc, 0x75, 0x2e, 0x3c, 0x62, 0x9f, 0x34,
  0xca, 0x10, 0x18, 0x69, 0x63, 0xb4, 0x4d, 0xd9, 0x40, 0x39, 0x40, 0xfb,
  0x24, 0x73, 0xeb, 0xca, 0xf6, 0x65, 0xe7, 0x78, 0x5e, 0xfb, 0xaf, 0x33,
  0xad, 0x5a, 0x08, 0x62, 0x82, 0x48, 0x7a, 0xf4, 0x77, 0xe3, 0xdb, 0x6a,
  0x58, 0xec, 0xc4, 0xf4, 0x57, 0xfa, 0x76, 0xfc, 0x5c, 0xa9, 0x32, 0x7f,
  0x00, 0x51, 0x09, 0x50, 0xe4,
]);
