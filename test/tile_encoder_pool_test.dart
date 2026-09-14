@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/codec/rgba_image.dart';
import 'package:svs/src/render/band_tile_encoder.dart';
import 'package:svs/src/render/tile_encoder_pool.dart';

void main() {
  const encoding = (jpeg2000: false, quality: 85, jp2kCompressionRatio: 0.0);

  test('encodes a band split across workers into the same tiles, in order, as '
      'encoding it inline', () async {
    // More tiles than workers, a narrow last tile, and a band shorter than
    // a tile.
    const width = 9 * 64 + 30, height = 40;
    final random = math.Random(3);
    final pixels = Uint8List.fromList(
      List.generate(width * height * 4, (_) => random.nextInt(256)),
    );
    final expected = BandTileEncoder(encoding).encode(
      RgbaImage(width, height, Uint8List.fromList(pixels)),
      tileWidth: 64,
      tileLength: 64,
    );

    final pool = await TileEncoderPool.start(encoding);
    addTearDown(pool.close);
    for (var band = 0; band < 2; band++) {
      final tiles = await pool.encodeBand(
        pixels,
        width: width,
        height: height,
        tileWidth: 64,
        tileLength: 64,
      );
      expect(tiles, hasLength(10));
      expect(tiles, expected);
    }
  });

  test('surfaces an error thrown inside a worker and keeps working', () async {
    final pool = await TileEncoderPool.start(encoding);
    addTearDown(pool.close);

    // Wider than JPEG allows, so the encoder throws on the worker.
    const tooWide = 70000;
    await expectLater(
      pool.encodeBand(
        Uint8List(tooWide * 4),
        width: tooWide,
        height: 1,
        tileWidth: tooWide,
        tileLength: 1,
      ),
      throwsA(isA<ArgumentError>()),
    );

    final tiles = await pool.encodeBand(
      Uint8List(16 * 4 * 4),
      width: 16,
      height: 4,
      tileWidth: 8,
      tileLength: 8,
    );
    expect(tiles, hasLength(2));
  });
}
