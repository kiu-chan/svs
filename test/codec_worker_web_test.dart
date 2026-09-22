// The web codec worker, for real: decodes and encodes on it from a page in
// Chrome (`flutter test --platform chrome`).
@TestOn('browser')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/codec/background_codec.dart';
import 'package:svs/src/codec/image_encoding.dart';
import 'package:svs/src/codec/jpeg2000/j2k_decoder.dart';
import 'package:svs/src/codec/jpeg2000/j2k_encoder.dart';
import 'package:svs/src/codec/rgba_image.dart';
import 'package:svs/src/render/band_tile_encoder.dart';
import 'package:svs/src/render/image_adjustments.dart';
import 'package:svs/src/render/tile_encoder_pool.dart';
import 'package:svs/src/web/codec_worker_pool.dart';

Uint8List _pixels(int n, int seed) {
  final random = math.Random(seed);
  return Uint8List.fromList([
    for (var i = 0; i < n; i++) (i * 7 + random.nextInt(40)) & 0xFF,
  ]);
}

void main() {
  test('workers start', () {
    expect(CodecWorkerPool.instance.size, greaterThan(0));
    expect(backgroundDecodeSlots, greaterThan(1));
  });

  test('decodes JPEG2000 on a worker, at full and reduced size', () async {
    final pixels = _pixels(96 * 80 * 3, 1);
    final codestream = encodeJ2k(
      pixels,
      width: 96,
      height: 80,
      numComponents: 3,
    );
    // A view into a larger buffer, as tiles read out of a slide are.
    final padded = Uint8List(codestream.length + 100)
      ..setRange(50, 50 + codestream.length, codestream);
    final view = Uint8List.sublistView(padded, 50, 50 + codestream.length);

    final full = await decodeJ2kInBackground(view);
    expect(full.pixels, pixels);
    final reduced = await decodeJ2kInBackground(
      view,
      reducedResolutionFactor: 2,
    );
    final local = decodeJ2k(codestream, reducedResolutionFactor: 2);
    expect(reduced.width, 24);
    expect(reduced.pixels, local.pixels);
    // The caller's buffer is untouched: only a copy went to the worker.
    expect(view, codestream);
  });

  test('many decodes in flight at once all come back', () async {
    final streams = [
      for (var i = 0; i < 12; i++)
        encodeJ2k(
          _pixels(40 * 30 * 3, i),
          width: 40,
          height: 30,
          numComponents: 3,
          compressionRatio: i.isEven ? 0 : 8,
        ),
    ];
    final decoded = await Future.wait(streams.map(decodeJ2kInBackground));
    for (var i = 0; i < streams.length; i++) {
      expect(decoded[i].pixels, decodeJ2k(streams[i]).pixels);
    }
  });

  test('a decode failure comes back as J2kDecodeException', () async {
    await expectLater(
      decodeJ2kInBackground(Uint8List.fromList([0xFF, 0x4F, 0xFF, 0x51])),
      throwsA(isA<J2kDecodeException>()),
    );
  });

  for (final jpeg2000 in [false, true]) {
    test('encodes export tiles on workers exactly as locally '
        '(${jpeg2000 ? 'JPEG2000' : 'JPEG'})', () async {
      const width = 700, height = 256, tile = 256;
      final band = _pixels(width * height * 4, 3);
      final encoding = (
        jpeg2000: jpeg2000,
        quality: 85,
        jp2kCompressionRatio: 12.0,
      );
      final pool = await TileEncoderPool.start(encoding);
      final tiles = await pool.encodeBand(
        band,
        width: width,
        height: height,
        tileWidth: tile,
        tileLength: tile,
      );
      await pool.close();
      final local = BandTileEncoder(encoding).encode(
        RgbaImage(width, height, band),
        tileWidth: tile,
        tileLength: tile,
      );
      expect(tiles, hasLength(3));
      for (var i = 0; i < tiles.length; i++) {
        expect(tiles[i], local[i]);
      }
    });
  }

  test('encodes a flat image on a worker exactly as locally', () async {
    final pixels = _pixels(64 * 40 * 4, 4);
    for (var format = 0; format < 5; format++) {
      final encoded = await encodeImageInBackground(
        Uint8List.fromList(pixels),
        64,
        40,
        format,
        80,
        SvsImageAdjustments.none,
      );
      expect(
        encoded,
        encodeRgbaImage(
          RgbaImage(64, 40, Uint8List.fromList(pixels)),
          format,
          80,
        ),
        reason: 'format $format',
      );
    }
  });
}
