import 'dart:io';
import 'dart:typed_data';

import 'package:openjpeg_ffi/openjpeg_ffi.dart';
import 'package:test/test.dart';

void main() {
  test(
    'decodes a real Aperio JP2K tile matching an independent (Pillow) oracle within CPU-rounding tolerance',
    () {
      // Fixture: IFD0/tile0 of a real JPEG2000-compressed Aperio SVS file
      // (CMU-1-JP2K-33005.svs), extracted via svs's own TiffFile reader.
      // Expected bytes computed independently via Python Pillow
      // (Image.open(io.BytesIO(tile_bytes)).convert('RGB').tobytes()) — a
      // different JPEG2000 decoder entirely, so a close match is strong
      // evidence this binding's stream callbacks and component interleaving
      // are correct, not just "didn't crash".
      final bytes = File('test/fixtures/tile0.j2k').readAsBytesSync();
      final expected = File(
        'test/fixtures/tile0_expected.rgb',
      ).readAsBytesSync();

      final image = decodeJ2k(bytes);

      expect(image.width, 240);
      expect(image.height, 240);
      expect(image.numComponents, 3);

      var mismatchCount = 0;
      var maxDiff = 0;
      for (var i = 0; i < expected.length; i++) {
        final diff = (image.pixels[i] - expected[i]).abs();
        if (diff > 0) {
          mismatchCount++;
          if (diff > maxDiff) maxDiff = diff;
        }
      }
      if (mismatchCount > 0) {
        // ignore: avoid_print
        print(
          'mismatch: $mismatchCount/${expected.length} bytes differ from the oracle, max abs diff $maxDiff',
        );
      }

      // Confirmed via CI on real x86_64 runners (both Linux and Windows):
      // exactly 1 of 172,800 bytes off by 1, at the same offset on both — this
      // slide's JP2K content uses the lossy, float-based irreversible 9/7
      // wavelet, whose inverse transform in OpenJPEG's own dwt.c/mct.c takes a
      // different SIMD codepath per architecture (x86 SSE2 vs. ARM NEON/
      // scalar), rounding the last bit differently. Not a bug in this binding
      // — macOS (arm64) matches the oracle exactly, and both x86_64 platforms
      // agree with each other bit-for-bit elsewhere. The bounds below allow
      // that kind of noise but still fail loudly on an actual decode bug.
      expect(
        maxDiff,
        lessThanOrEqualTo(1),
        reason:
            'diverges from the oracle by more than expected CPU-rounding noise',
      );
      expect(
        mismatchCount,
        lessThanOrEqualTo(32),
        reason: 'too many differing bytes to be just rounding noise',
      );
    },
  );

  test('throws Jp2kDecodeException on garbage input', () {
    final garbage = Uint8List.fromList(List<int>.filled(64, 0));
    expect(() => decodeJ2k(garbage), throwsA(isA<Jp2kDecodeException>()));
  });
}
