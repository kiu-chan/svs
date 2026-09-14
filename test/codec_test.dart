@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:svs/src/codec/bmp_encoder.dart';
import 'package:svs/src/codec/deflate.dart';
import 'package:svs/src/codec/huffman.dart';
import 'package:svs/src/codec/inflate.dart';
import 'package:svs/src/codec/jpeg_encoder.dart';
import 'package:svs/src/codec/png_encoder.dart';
import 'package:svs/src/codec/rgba_image.dart';
import 'package:svs/src/codec/tiff_encoder.dart';
import 'package:svs/src/codec/webp_encoder.dart';
import 'package:svs/src/codec/zlib.dart';

// Encoder output is checked against two independent decoders: package:image
// (a test-only dependency) and the Flutter engine's own codecs — the ones an
// app displaying these files actually uses.

/// Deterministic content covering what encoders treat differently: a smooth
/// gradient (top third), a flat fill (middle third — LZ77 runs, zero
/// residuals) and, if [noise], per-pixel noise (bottom third — dense prefix
/// codes; otherwise more flat fill). Unless [opaque], alpha varies too.
RgbaImage _testImage(
  int width,
  int height, {
  bool opaque = true,
  bool noise = true,
}) {
  final random = math.Random(width * 31 + height);
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = (y * width + x) * 4;
      final band = y * 3 ~/ height;
      if (band == 0) {
        pixels[p] = x * 255 ~/ math.max(1, width - 1);
        pixels[p + 1] = y * 255 ~/ math.max(1, height - 1);
        pixels[p + 2] = 128;
      } else if (band == 1 || !noise) {
        pixels[p] = 30;
        pixels[p + 1] = 200;
        pixels[p + 2] = 60;
      } else {
        pixels[p] = random.nextInt(256);
        pixels[p + 1] = random.nextInt(256);
        pixels[p + 2] = random.nextInt(256);
      }
      pixels[p + 3] = opaque ? 255 : (x * 37 + y * 11) & 0xff;
    }
  }
  return RgbaImage(width, height, pixels);
}

RgbaImage _opaqueImage(int width, int height, int Function(int x, int y) rgb) {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = (y * width + x) * 4;
      final color = rgb(x, y);
      pixels[p] = color >> 16;
      pixels[p + 1] = (color >> 8) & 0xff;
      pixels[p + 2] = color & 0xff;
      pixels[p + 3] = 255;
    }
  }
  return RgbaImage(width, height, pixels);
}

Future<Uint8List> _decodeWithEngine(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  frame.image.dispose();
  codec.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// [decoded]'s pixels as RGBA bytes, with opaque alpha added only if it has
/// no alpha channel of its own.
Uint8List _rgbaOf(img.Image decoded) =>
    (decoded.numChannels == 4
            ? decoded
            : decoded.convert(numChannels: 4, alpha: 255))
        .getBytes(order: img.ChannelOrder.rgba);

double _meanAbsoluteRgbError(Uint8List actual, Uint8List expected) {
  expect(actual.length, expected.length);
  var sum = 0;
  for (var p = 0; p < actual.length; p += 4) {
    for (var c = 0; c < 3; c++) {
      sum += (actual[p + c] - expected[p + c]).abs();
    }
  }
  return sum / (actual.length ~/ 4 * 3);
}

Uint8List _randomBytes(int length, int seed) {
  final random = math.Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

const _sizes = [(1, 1), (5, 3), (16, 16), (37, 23), (130, 70)];

void main() {
  group('zlib', () {
    final samples = {
      'empty': Uint8List(0),
      'short text': Uint8List.fromList('abracadabra abracadabra'.codeUnits),
      'random': _randomBytes(100000, 1),
      'long runs': Uint8List.fromList(
        List.generate(300000, (i) => (i ~/ 5000) % 3),
      ),
      'mixed': Uint8List.fromList([
        ..._randomBytes(40000, 2),
        ...List.filled(70000, 9),
        ..._randomBytes(40000, 2),
      ]),
    };

    for (final MapEntry(key: name, value: data) in samples.entries) {
      test('inflateZlib decodes dart:io output ($name)', () {
        for (final level in [0, 1, 6, 9]) {
          final compressed = Uint8List.fromList(
            ZLibCodec(level: level).encode(data),
          );
          expect(inflateZlib(compressed), data, reason: 'level $level');
        }
      });

      test('deflateZlib output decodes with dart:io and inflateZlib ($name)', () {
        final compressed = deflateZlib(data);
        expect(zlib.decode(compressed), data);
        expect(inflateZlib(compressed), data);
      });
    }

    test('deflateZlib compresses redundancy and barely expands noise', () {
      expect(deflateZlib(samples['long runs']!).length, lessThan(2000));
      final random = samples['random']!;
      expect(deflateZlib(random).length, lessThan(random.length + 100));
    });

    test('inflateZlib rejects malformed and truncated streams', () {
      expect(
        () => inflateZlib(Uint8List.fromList([1, 2, 3, 4])),
        throwsFormatException,
      );
      final compressed = Uint8List.fromList(zlib.encode(samples['mixed']!));
      expect(
        () => inflateZlib(
          Uint8List.sublistView(compressed, 0, compressed.length ~/ 2),
        ),
        throwsFormatException,
      );
    });

    test('the platform zlibEncode/zlibDecode round-trip', () {
      final data = samples['mixed']!;
      expect(zlibDecode(zlibEncode(data)), data);
    });
  });

  test('huffmanCodeLengths caps code length and keeps the code complete', () {
    // Fibonacci counts build a maximally skewed tree (depth 29) uncapped.
    final counts = [1, 1];
    while (counts.length < 30) {
      counts.add(counts[counts.length - 1] + counts[counts.length - 2]);
    }
    for (final maxLength in [7, 15]) {
      final lengths = huffmanCodeLengths(counts, maxLength);
      expect(lengths.every((l) => l >= 1 && l <= maxLength), isTrue);
      final kraftSum = lengths.fold<double>(
        0,
        (sum, l) => sum + math.pow(2, -l),
      );
      expect(kraftSum, 1.0);
    }
  });

  group('RgbaImage', () {
    RgbaImage numbered(int width, int height) => RgbaImage(
      width,
      height,
      Uint8List.fromList(List.generate(width * height * 4, (i) => i)),
    );

    test('crop copies the requested rectangle', () {
      final image = numbered(3, 2);
      expect(image.crop(x: 1, y: 1, width: 2, height: 1).pixels, [
        16, 17, 18, 19, 20, 21, 22, 23, //
      ]);
      expect(
        () => image.crop(x: 2, y: 0, width: 2, height: 1),
        throwsRangeError,
      );
    });

    test('rgbBytes drops alpha and pads with black', () {
      expect(
        numbered(2, 1).rgbBytes(
          x: 1,
          y: 0,
          width: 1,
          height: 1,
          outWidth: 2,
          outHeight: 2,
        ),
        [4, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      );
    });

    test('resizeAverage averages each output pixel\'s footprint', () {
      final image = RgbaImage(
        4,
        2,
        Uint8List.fromList([
          0, 0, 0, 0, 10, 20, 30, 40, 100, 100, 100, 100, 200, 200, 200, 200, //
          2, 2, 2, 2, 12, 22, 32, 42, 101, 101, 101, 101, 201, 201, 201, 201,
        ]),
      );
      expect(image.resizeAverage(2, 1).pixels, [
        6, 11, 16, 21, 151, 151, 151, 151, //
      ]);
      expect(
        RgbaImage(1, 1, Uint8List.fromList([9, 8, 7, 6]))
            .resizeAverage(3, 2)
            .pixels,
        List.generate(24, (i) => 9 - i % 4),
      );
    });

    test('blit overwrites only the overlapping pixels', () {
      final target = RgbaImage.blank(2, 2);
      target.blit(
        RgbaImage(2, 2, Uint8List(16)..fillRange(0, 16, 9)),
        dstX: 1,
        dstY: -1,
      );
      expect(target.pixels, [0, 0, 0, 0, 9, 9, 9, 9, 0, 0, 0, 0, 0, 0, 0, 0]);
    });
  });

  group('encoders', () {
    for (final (width, height) in _sizes) {
      final size = '${width}x$height';

      test('PNG $size is lossless', () async {
        final image = _testImage(width, height, opaque: false);
        expect(_rgbaOf(img.decodePng(encodePng(image))!), image.pixels);
        final opaque = _testImage(width, height);
        expect(await _decodeWithEngine(encodePng(opaque)), opaque.pixels);
      });

      test('WebP $size is lossless', () async {
        final image = _testImage(width, height, opaque: false);
        expect(_rgbaOf(img.decodeWebP(encodeWebP(image))!), image.pixels);
        final opaque = _testImage(width, height);
        expect(await _decodeWithEngine(encodeWebP(opaque)), opaque.pixels);
      });

      test('BMP $size keeps RGB exactly', () async {
        final image = _testImage(width, height);
        final bytes = encodeBmp(image);
        expect(_rgbaOf(img.decodeBmp(bytes)!), image.pixels);
        expect(await _decodeWithEngine(bytes), image.pixels);
      });

      test('TIFF $size is lossless', () {
        final image = _testImage(width, height, opaque: false);
        expect(_rgbaOf(img.decodeTiff(encodeTiff(image))!), image.pixels);
      });

      test('JPEG $size decodes close to the source', () async {
        final image = _testImage(width, height, noise: false);
        final bytes = JpegEncoder(quality: 95).encode(image);
        final decoded = img.decodeJpg(bytes)!;
        expect((decoded.width, decoded.height), (width, height));
        expect(
          _meanAbsoluteRgbError(_rgbaOf(decoded), image.pixels),
          lessThan(3),
        );
        expect(
          _meanAbsoluteRgbError(await _decodeWithEngine(bytes), image.pixels),
          lessThan(3),
        );
      });
    }

    test('JPEG clamps quality and encodes dense noise at every quality', () async {
      expect(JpegEncoder(quality: 0).quality, 1);
      expect(JpegEncoder(quality: 500).quality, 100);
      final image = _testImage(64, 64);
      for (final quality in [1, 50, 100]) {
        final decoded = await _decodeWithEngine(
          JpegEncoder(quality: quality).encode(image),
        );
        expect(decoded.length, image.pixels.length);
        if (quality == 100) {
          expect(_meanAbsoluteRgbError(decoded, image.pixels), lessThan(3));
        }
      }
    });

    test('WebP handles flat, checkerboard and very wide images', () async {
      final cases = {
        'flat': _opaqueImage(300, 200, (x, y) => 0x336699),
        'checkerboard': _opaqueImage(
          33,
          17,
          (x, y) => (x + y).isEven ? 0xffffff : 0x000000,
        ),
        'stripes': _opaqueImage(
          5000,
          3,
          (x, y) => (x ~/ 700).isEven ? 0xff0000 : 0x00ff00,
        ),
      };
      for (final MapEntry(key: name, value: image) in cases.entries) {
        final bytes = encodeWebP(image);
        expect(_rgbaOf(img.decodeWebP(bytes)!), image.pixels, reason: name);
        expect(await _decodeWithEngine(bytes), image.pixels, reason: name);
      }
    });

    test('WebP rejects dimensions VP8L can\'t describe', () {
      expect(
        () => encodeWebP(RgbaImage(16384, 1, Uint8List(16384 * 4))),
        throwsArgumentError,
      );
    });
  });
}
