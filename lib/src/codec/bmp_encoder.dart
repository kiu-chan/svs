import 'dart:typed_data';

import 'rgba_image.dart';

/// Encodes [image] as an uncompressed 24-bit BMP (`BITMAPINFOHEADER`,
/// bottom-up rows). Alpha is dropped.
Uint8List encodeBmp(RgbaImage image) {
  final width = image.width;
  final height = image.height;
  if (width < 1 || height < 1) {
    throw ArgumentError('BMP needs at least a 1x1 image, got ${width}x$height');
  }
  const headerLength = 14 + 40;
  final rowLength = (width * 3 + 3) ~/ 4 * 4;
  final pixelDataLength = rowLength * height;
  final fileLength = headerLength + pixelDataLength;
  if (fileLength > 0xffffffff) {
    throw ArgumentError('${width}x$height is too large for a BMP file');
  }

  final bytes = Uint8List(fileLength);
  const le = Endian.little;
  bytes[0] = 0x42; // 'B'
  bytes[1] = 0x4d; // 'M'
  ByteData.sublistView(bytes, 0, headerLength)
    ..setUint32(2, fileLength, le)
    ..setUint32(10, headerLength, le)
    ..setUint32(14, 40, le) // BITMAPINFOHEADER size
    ..setInt32(18, width, le)
    ..setInt32(22, height, le) // positive: rows stored bottom-up
    ..setUint16(26, 1, le) // planes
    ..setUint16(28, 24, le) // bits per pixel
    ..setUint32(30, 0, le) // BI_RGB
    ..setUint32(34, pixelDataLength, le)
    ..setInt32(38, 2835, le) // 72 DPI, in pixels per meter
    ..setInt32(42, 2835, le);

  final pixels = image.pixels;
  for (var y = 0; y < height; y++) {
    var from = (height - 1 - y) * width * 4;
    var to = headerLength + y * rowLength;
    for (var x = 0; x < width; x++) {
      bytes[to] = pixels[from + 2];
      bytes[to + 1] = pixels[from + 1];
      bytes[to + 2] = pixels[from];
      from += 4;
      to += 3;
    }
  }
  return bytes;
}
