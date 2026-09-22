import 'dart:typed_data';

import '../codec/rgba_image.dart';
import 'band_tile_encoder.dart';

/// Encodes a pyramid export's tiles on the calling thread, where neither
/// isolates (`dart:io` platforms) nor Web Workers (the web) are available.
class TileEncoderPool {
  final BandTileEncoder _encoder;

  TileEncoderPool._(this._encoder);

  static Future<TileEncoderPool> start(TileEncoding encoding) async =>
      TileEncoderPool._(BandTileEncoder(encoding));

  /// Encodes every tile of a [width]x[height] band of RGBA [pixels], tiled
  /// at [tileWidth]x[tileLength], left to right.
  Future<List<Uint8List>> encodeBand(
    Uint8List pixels, {
    required int width,
    required int height,
    required int tileWidth,
    required int tileLength,
  }) async => _encoder.encode(
    RgbaImage(width, height, pixels),
    tileWidth: tileWidth,
    tileLength: tileLength,
  );

  Future<void> close() async {}
}
