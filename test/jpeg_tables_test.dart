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
}
