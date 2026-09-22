// Runs on the VM and on the web (`flutter test --platform chrome`): the
// codec's bit twiddling has to come out the same under dart2js's number
// semantics as on the VM, where j2k_conformance_test.dart checks it against
// OpenJPEG.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/codec/jpeg2000/j2k_decoder.dart';
import 'package:svs/src/codec/jpeg2000/j2k_encoder.dart';

import 'j2k_fingerprint.dart';
import 'j2k_fixtures.g.dart';

/// A 240x240 texture with smooth regions, edges and noise, roughly like a
/// slide tile.
Uint8List _texture(int channels) {
  final random = math.Random(5);
  const size = 240;
  final pixels = Uint8List(size * size * channels);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final cell = ((x ~/ 30) + (y ~/ 30)).isEven ? 60 : 0;
      for (var c = 0; c < channels; c++) {
        final v =
            128 +
            80 * math.sin((x + 17 * c) / 11) * math.cos(y / 13) +
            cell -
            30 +
            random.nextInt(24);
        pixels[(y * size + x) * channels + c] = v.clamp(0, 255).toInt();
      }
    }
  }
  return pixels;
}

double _psnr(Uint8List a, Uint8List b) {
  var se = 0.0;
  for (var i = 0; i < a.length; i++) {
    se += (a[i] - b[i]) * (a[i] - b[i]);
  }
  return se == 0
      ? double.infinity
      : 10 * math.log(255 * 255 * a.length / se) / math.ln10;
}

void main() {
  group('decodes every fixture as on the VM', () {
    for (final MapEntry(key: name, value: data) in j2kFixtures.entries) {
      test(name, () {
        final bytes = base64Decode(data);
        for (var reduce = 0; reduce <= 2; reduce++) {
          final expected = j2kFingerprints['$name/$reduce'];
          if (expected == 'error') {
            expect(
              () => decodeJ2k(bytes, reducedResolutionFactor: reduce),
              throwsA(isA<J2kDecodeException>()),
            );
          } else {
            final image = decodeJ2k(bytes, reducedResolutionFactor: reduce);
            expect(fingerprint(image), expected, reason: 'reduced $reduce');
          }
        }
      });
    }
  });

  for (final channels in [1, 3, 4]) {
    final pixels = _texture(channels);

    test('lossless encoding round-trips ($channels channels)', () {
      final codestream = encodeJ2k(
        pixels,
        width: 240,
        height: 240,
        numComponents: channels,
      );
      final image = decodeJ2k(codestream);
      expect(image.width, 240);
      expect(image.height, 240);
      expect(image.numComponents, channels);
      expect(image.pixels, pixels);
      expect(codestream.length, lessThan(pixels.length));
    });

    test('lossy encoding meets its size and keeps detail ($channels '
        'channels)', () {
      var previous = double.infinity;
      for (final ratio in [4.0, 10.0, 30.0]) {
        final codestream = encodeJ2k(
          pixels,
          width: 240,
          height: 240,
          numComponents: channels,
          compressionRatio: ratio,
        );
        expect(codestream.length, lessThanOrEqualTo(pixels.length / ratio));
        final psnr = _psnr(pixels, decodeJ2k(codestream).pixels);
        expect(psnr, greaterThan(25), reason: 'ratio $ratio');
        expect(psnr, lessThan(previous), reason: 'ratio $ratio');
        previous = psnr;
      }
    });
  }

  test('reduced-resolution decode of an encoded tile', () {
    final pixels = _texture(3);
    final codestream = encodeJ2k(
      pixels,
      width: 240,
      height: 240,
      numComponents: 3,
    );
    for (final (reduce, size) in [(1, 120), (3, 30), (5, 8)]) {
      final image = decodeJ2k(codestream, reducedResolutionFactor: reduce);
      expect(image.width, size);
      expect(image.height, size);
    }
    expect(
      () => decodeJ2k(codestream, reducedResolutionFactor: 6),
      throwsA(isA<J2kDecodeException>()),
    );
  });

  test('small and odd-sized rasters encode losslessly', () {
    for (final (w, h) in [(1, 1), (2, 1), (1, 5), (37, 29), (65, 3)]) {
      final pixels = Uint8List.fromList([
        for (var i = 0; i < w * h * 3; i++) (i * 37 + i ~/ 5) & 0xFF,
      ]);
      final image = decodeJ2k(
        encodeJ2k(pixels, width: w, height: h, numComponents: 3),
      );
      expect(image.pixels, pixels, reason: '${w}x$h');
    }
  });

  test('rejects malformed input', () {
    expect(
      () => decodeJ2k(Uint8List.fromList([0xFF, 0x4F, 0xFF])),
      throwsA(isA<J2kDecodeException>()),
    );
    expect(
      () => decodeJ2k(Uint8List.fromList([1, 2, 3, 4])),
      throwsA(isA<J2kDecodeException>()),
    );
    final truncated = base64Decode(j2kFixtures['lossless']!);
    // A codestream cut off mid-tile still decodes what arrived.
    decodeJ2k(Uint8List.sublistView(truncated, 0, truncated.length ~/ 2));
    expect(
      () => encodeJ2k(Uint8List(4), width: 2, height: 2, numComponents: 5),
      throwsA(isA<J2kEncodeException>()),
    );
  });
}
