// Checks this package's JPEG2000 encoder against OpenJPEG (a dev-only
// dependency): OpenJPEG must decode its codestreams exactly as this
// package's decoder does, and at a given size ratio it must keep about as
// much detail as OpenJPEG's own encoder (which svs's exports used before).
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openjpeg_ffi/openjpeg_ffi.dart' as opj;
import 'package:svs/src/codec/jpeg2000/j2k_decoder.dart';
import 'package:svs/src/codec/jpeg2000/j2k_encoder.dart';

Uint8List _texture(int w, int h, int channels, int seed) {
  final random = math.Random(seed);
  final pixels = Uint8List(w * h * channels);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < channels; c++) {
        final v =
            128 +
            90 * math.sin((x + 23 * c) / 9) * math.cos(y / 15) +
            random.nextInt(30) -
            15;
        pixels[(y * w + x) * channels + c] = v.clamp(0, 255).toInt();
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
  for (final (w, h, n) in [(240, 240, 3), (256, 200, 1), (61, 47, 4)]) {
    final pixels = _texture(w, h, n, w + n);

    test('OpenJPEG decodes a lossless ${w}x$h x$n codestream exactly', () {
      final codestream = encodeJ2k(
        pixels,
        width: w,
        height: h,
        numComponents: n,
      );
      expect(opj.decodeJ2k(codestream).pixels, pixels);
      // Within a few percent of OpenJPEG's own lossless output.
      final theirs = opj.encodeJ2k(
        pixels,
        width: w,
        height: h,
        numComponents: n,
      );
      expect(codestream.length, lessThan(theirs.length * 1.05));
    });

    for (final ratio in [5.0, 15.0, 40.0]) {
      test('lossy ${w}x$h x$n at $ratio:1 matches OpenJPEG', () {
        final codestream = encodeJ2k(
          pixels,
          width: w,
          height: h,
          numComponents: n,
          compressionRatio: ratio,
        );
        final ours = decodeJ2k(codestream).pixels;
        final reference = opj.decodeJ2k(codestream).pixels;
        var maxDiff = 0;
        for (var i = 0; i < ours.length; i++) {
          maxDiff = math.max(maxDiff, (ours[i] - reference[i]).abs());
        }
        expect(maxDiff, lessThanOrEqualTo(1));

        final theirs = opj.encodeJ2k(
          pixels,
          width: w,
          height: h,
          numComponents: n,
          compressionRatio: ratio,
        );
        final theirPsnr = _psnr(pixels, opj.decodeJ2k(theirs).pixels);
        expect(codestream.length, lessThanOrEqualTo(pixels.length / ratio));
        expect(_psnr(pixels, ours), greaterThan(theirPsnr - 0.5));
      });
    }
  }
}
