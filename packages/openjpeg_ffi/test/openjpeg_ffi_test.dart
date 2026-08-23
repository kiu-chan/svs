import 'dart:io';
import 'dart:typed_data';

import 'package:openjpeg_ffi/openjpeg_ffi.dart';
import 'package:test/test.dart';

void main() {
  test('decodes a real Aperio JP2K tile pixel-exact against an independent (Pillow) oracle', () {
    // Fixture: IFD0/tile0 of a real JPEG2000-compressed Aperio SVS file
    // (CMU-1-JP2K-33005.svs), extracted via svs's own TiffFile reader.
    // Expected bytes computed independently via Python Pillow
    // (Image.open(io.BytesIO(tile_bytes)).convert('RGB').tobytes()) — a
    // different JPEG2000 decoder entirely, so an exact match is strong
    // evidence this binding's stream callbacks and component interleaving
    // are correct, not just "didn't crash".
    final bytes = File('test/fixtures/tile0.j2k').readAsBytesSync();
    final expected = File('test/fixtures/tile0_expected.rgb').readAsBytesSync();

    final image = decodeJ2k(bytes);

    expect(image.width, 240);
    expect(image.height, 240);
    expect(image.numComponents, 3);

    // Diagnostic ahead of the strict equality check below: if this diverges
    // only on Linux/Windows CI runners (not macOS), the leading candidate is
    // CPU-architecture rounding noise in OpenJPEG's own float-based inverse
    // wavelet transform (x86 SSE vs ARM NEON codepaths in its dwt.c/mct.c),
    // not a bug in this binding — but that's a guess pending this data.
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
      print('mismatch: $mismatchCount/${expected.length} bytes differ from the oracle, max abs diff $maxDiff');
    }

    expect(image.pixels, expected);
  });

  test('throws Jp2kDecodeException on garbage input', () {
    final garbage = Uint8List.fromList(List<int>.filled(64, 0));
    expect(() => decodeJ2k(garbage), throwsA(isA<Jp2kDecodeException>()));
  });
}
