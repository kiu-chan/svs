import 'dart:math' as math;
import 'dart:typed_data';

import '../codec/jpeg2000/j2k_encoder.dart';
import '../codec/jpeg_encoder.dart';
import '../codec/rgba_image.dart';

/// How every tile of one pyramid export is encoded.
typedef TileEncoding = ({
  bool jpeg2000,
  int quality,
  double jp2kCompressionRatio,
});

/// Encodes rows of pyramid tiles from their decoded pixels.
class BandTileEncoder {
  final TileEncoding encoding;

  /// Created on first use — JPEG2000 exports never need it.
  late final _jpegEncoder = JpegEncoder(quality: encoding.quality);

  BandTileEncoder(this.encoding);

  /// Encodes, left to right, the tiles covering [region]: part of one row
  /// band of a level tiled at [tileWidth]x[tileLength], starting at a tile
  /// boundary. Its last tile may be narrower than [tileWidth], and the band
  /// shorter than [tileLength] at the level's bottom edge.
  List<Uint8List> encode(
    RgbaImage region, {
    required int tileWidth,
    required int tileLength,
  }) {
    final tiles = <Uint8List>[];
    for (var left = 0; left < region.width; left += tileWidth) {
      final width = math.min(tileWidth, region.width - left);
      if (encoding.jpeg2000) {
        // Unlike JPEG tiles — whose readers (`region_decoder.dart`,
        // `lod_controller.dart`) already handle a boundary tile decoding
        // smaller than nominal — every JP2K reader in this package assumes a
        // tile decodes at exactly the nominal tile-grid size (true of real
        // Aperio JP2K files, which always pad). So a boundary tile is padded
        // up to that full nominal size before encoding, rather than encoded
        // at its true (smaller) size like a JPEG tile.
        tiles.add(
          encodeJ2k(
            region.rgbBytes(
              x: left,
              y: 0,
              width: width,
              height: region.height,
              outWidth: tileWidth,
              outHeight: tileLength,
            ),
            width: tileWidth,
            height: tileLength,
            numComponents: 3,
            compressionRatio: encoding.jp2kCompressionRatio,
          ),
        );
      } else {
        tiles.add(
          _jpegEncoder.encode(
            region.crop(x: left, y: 0, width: width, height: region.height),
          ),
        );
      }
    }
    return tiles;
  }
}
