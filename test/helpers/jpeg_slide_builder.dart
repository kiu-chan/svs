// An in-memory, JPEG-tiled single-level slide with real decodable tiles,
// built with this package's own (pure-Dart) JpegEncoder rather than
// package:image or dart:io, so tests that decode or export it run on the web
// as well as the VM.
import 'dart:typed_data';

import 'package:svs/src/codec/jpeg_encoder.dart';
import 'package:svs/src/codec/rgba_image.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'tiff_builder.dart';

/// A [width]x[height] slide of [tileSize] tiles, each filled with a
/// gradient that differs per tile, followed by the tiles' JPEG bytes.
Uint8List buildJpegTiledSlide({
  required int width,
  required int height,
  int tileSize = 256,
}) {
  final tilesX = tilesAcross(width, tileSize);
  final tilesY = tilesAcross(height, tileSize);
  final encoder = JpegEncoder(quality: 90);
  final tiles = <Uint8List>[
    for (var ty = 0; ty < tilesY; ty++)
      for (var tx = 0; tx < tilesX; tx++)
        encoder.encode(_gradientTile(tileSize, tx, ty)),
  ];

  // Tile offsets are fixed-size LONGs, so their values don't change the
  // structure's length: build once to measure it, then with real offsets.
  Uint8List structure(int dataStart) {
    final offsets = <int>[];
    var pos = dataStart;
    for (final tile in tiles) {
      offsets.add(pos);
      pos += tile.length;
    }
    return buildTiff(
      bigTiff: false,
      order: Endian.little,
      ifds: [
        [
          TestTag.ints(256, TiffType.long, [width], Endian.little),
          TestTag.ints(257, TiffType.long, [height], Endian.little),
          TestTag.ints(259, TiffType.short, [7], Endian.little),
          TestTag.ascii(
            270,
            'Aperio Image Library v11.2.1\r\n${width}x$height '
            '($tileSize x $tileSize) JPEG/RGB Q=90|AppMag = 20|MPP = 0.5',
          ),
          TestTag.ints(322, TiffType.long, [tileSize], Endian.little),
          TestTag.ints(323, TiffType.long, [tileSize], Endian.little),
          TestTag.ints(324, TiffType.long, offsets, Endian.little),
          TestTag.ints(325, TiffType.long, [
            for (final tile in tiles) tile.length,
          ], Endian.little),
        ],
      ],
    );
  }

  final dataStart = structure(0).length;
  final out = BytesBuilder(copy: false)..add(structure(dataStart));
  tiles.forEach(out.add);
  return out.toBytes();
}

RgbaImage _gradientTile(int size, int tx, int ty) {
  final pixels = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final p = (y * size + x) * 4;
      pixels[p] = (x + tx * 60) & 0xff;
      pixels[p + 1] = (y + ty * 60) & 0xff;
      pixels[p + 2] = (x + y) & 0xff;
      pixels[p + 3] = 255;
    }
  }
  return RgbaImage(size, size, pixels);
}
