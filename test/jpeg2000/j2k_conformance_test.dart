// Checks this package's JPEG2000 decoder against OpenJPEG (a dev-only
// dependency) on codestreams OpenJPEG itself wrote with every feature
// test/fixtures/jpeg2000/generate.sh turns on: both wavelets and component
// transforms, layers, all five progression orders and POC, precincts,
// every code-block style, SOP/EPH, tiles and tile-parts with offsets, ROI,
// 16-bit and subsampled components — at full and reduced resolution. Also
// checks test/jpeg2000/j2k_fixtures.g.dart is up to date, since the web
// tests rely on it.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openjpeg_ffi/openjpeg_ffi.dart' as opj;
import 'package:svs/src/codec/jpeg2000/j2k_decoder.dart';

import 'j2k_fingerprint.dart';
import 'j2k_fixtures.g.dart';

void main() {
  final files =
      Directory('test/fixtures/jpeg2000')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.j2k'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('every fixture is embedded for the web tests', () {
    expect(
      j2kFixtures.keys.toSet(),
      {for (final f in files) f.uri.pathSegments.last.replaceAll('.j2k', '')},
      reason: 'rerun tool/generate_jpeg2000_fixtures.dart',
    );
  });

  for (final file in files) {
    final name = file.uri.pathSegments.last.replaceAll('.j2k', '');
    for (var reduce = 0; reduce <= 2; reduce++) {
      test('$name, reduced $reduce', () {
        final bytes = file.readAsBytesSync();
        opj.Jp2kImage? reference;
        try {
          reference = opj.decodeJ2k(bytes, reducedResolutionFactor: reduce);
        } on opj.Jp2kDecodeException {
          // OpenJPEG refuses to discard more levels than there are; so must
          // we.
        }
        if (reference == null) {
          expect(
            () => decodeJ2k(bytes, reducedResolutionFactor: reduce),
            throwsA(isA<J2kDecodeException>()),
          );
          expect(j2kFingerprints['$name/$reduce'], 'error');
          return;
        }
        final image = decodeJ2k(bytes, reducedResolutionFactor: reduce);
        expect(j2kFingerprints['$name/$reduce'], fingerprint(image));

        // OpenJPEG 0.3.1's binding reports a reduced decode at full canvas
        // size with the image in its top-left corner.
        final n = image.numComponents;
        expect(n, reference.numComponents);
        var maxDiff = 0;
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            for (var c = 0; c < n; c++) {
              final d =
                  image.pixels[(y * image.width + x) * n + c] -
                  reference.pixels[(y * reference.width + x) * n + c];
              if (d.abs() > maxDiff) maxDiff = d.abs();
            }
          }
        }
        // Irreversible decodes round differently in places: OpenJPEG works
        // in single precision.
        expect(maxDiff, lessThanOrEqualTo(1));
      });
    }
  }
}
