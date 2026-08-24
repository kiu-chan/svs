import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/jpeg/jpeg_tables.dart';

void main() {
  test('splices tables (minus EOI) with tile scan data (minus SOI)', () {
    final tables = Uint8List.fromList([
      0xFF,
      0xD8,
      0xAA,
      0xBB,
      0xCC,
      0xFF,
      0xD9,
    ]);
    final tile = Uint8List.fromList([0xFF, 0xD8, 0xDD, 0xEE, 0xFF, 0xD9]);

    final spliced = spliceJpegTile(tables, tile);

    expect(spliced, [0xFF, 0xD8, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0xD9]);
  });

  test('passes tile bytes through unchanged when JPEGTables is null', () {
    final tile = Uint8List.fromList([0xFF, 0xD8, 0x11, 0x22, 0xFF, 0xD9]);
    expect(spliceJpegTile(null, tile), same(tile));
  });

  test('passes tile bytes through unchanged when JPEGTables is empty', () {
    final tile = Uint8List.fromList([0xFF, 0xD8, 0x11, 0x22, 0xFF, 0xD9]);
    expect(spliceJpegTile(Uint8List(0), tile), same(tile));
  });

  test('tolerates a tile or tables blob that lacks the expected markers', () {
    // Defensive: if a marker is missing, splice whatever is there rather
    // than throw — a malformed result will simply fail to decode later,
    // which is caught and surfaced per-tile.
    final tables = Uint8List.fromList([0xAA, 0xBB]);
    final tile = Uint8List.fromList([0xCC, 0xDD]);
    expect(spliceJpegTile(tables, tile), [0xAA, 0xBB, 0xCC, 0xDD]);
  });

  group('forceRgbColorTransform', () {
    test('inserts an Adobe transform=0 APP14 segment right after SOI', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0x11, 0x22, 0xFF, 0xD9]);

      final result = forceRgbColorTransform(jpeg);

      expect(result, [
        0xFF, 0xD8, // SOI, untouched
        0xFF, 0xEE, // APP14
        0x00, 0x0E, // length = 14
        0x41, 0x64, 0x6F, 0x62, 0x65, // "Adobe"
        0x00, 0x64, // version 100
        0x00, 0x00, // flags0
        0x00, 0x00, // flags1
        0x00, // transform = 0
        0x11, 0x22, 0xFF, 0xD9, // the rest of the original bytes, untouched
      ]);
    });

    test('leaves bytes unchanged when they do not start with a valid SOI', () {
      final notAJpeg = Uint8List.fromList([0x00, 0x11, 0x22]);
      expect(forceRgbColorTransform(notAJpeg), same(notAJpeg));
    });

    test('leaves an empty or 1-byte input unchanged', () {
      expect(forceRgbColorTransform(Uint8List(0)), isEmpty);
      final oneByte = Uint8List.fromList([0xFF]);
      expect(forceRgbColorTransform(oneByte), same(oneByte));
    });
  });
}
