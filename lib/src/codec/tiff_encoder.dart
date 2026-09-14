import 'dart:typed_data';

import '../tiff/tiff_types.dart';
import 'rgba_image.dart';

/// Encodes [image] as a baseline little-endian TIFF: a single uncompressed
/// strip of 8-bit RGBA, alpha marked as unassociated (`ExtraSamples` = 2).
Uint8List encodeTiff(RgbaImage image) {
  final width = image.width;
  final height = image.height;
  if (width < 1 || height < 1) {
    throw ArgumentError(
      'TIFF needs at least a 1x1 image, got ${width}x$height',
    );
  }
  const entryCount = 14;
  const ifdOffset = 8;
  const bitsPerSampleOffset = ifdOffset + 2 + entryCount * 12 + 4;
  const xResolutionOffset = bitsPerSampleOffset + 8;
  const yResolutionOffset = xResolutionOffset + 8;
  const pixelDataOffset = yResolutionOffset + 8;
  final pixelDataLength = width * height * 4;
  final fileLength = pixelDataOffset + pixelDataLength;
  if (fileLength > 0xffffffff) {
    throw ArgumentError(
      '${width}x$height is too large for a classic (4 GB) TIFF file',
    );
  }

  final bytes = Uint8List(fileLength);
  final view = ByteData.sublistView(bytes);
  const le = Endian.little;
  bytes[0] = 0x49; // 'I'
  bytes[1] = 0x49; // 'I'
  view
    ..setUint16(2, 42, le)
    ..setUint32(4, ifdOffset, le)
    ..setUint16(ifdOffset, entryCount, le);

  var entry = ifdOffset + 2;
  void tag(int id, int type, int count, int value) {
    view
      ..setUint16(entry, id, le)
      ..setUint16(entry + 2, type, le)
      ..setUint32(entry + 4, count, le);
    if (type == TiffType.short && count == 1) {
      view.setUint16(entry + 8, value, le);
    } else {
      view.setUint32(entry + 8, value, le);
    }
    entry += 12;
  }

  // Entries must be sorted by tag ID.
  tag(256, TiffType.long, 1, width); // ImageWidth
  tag(257, TiffType.long, 1, height); // ImageLength
  tag(258, TiffType.short, 4, bitsPerSampleOffset); // BitsPerSample
  tag(259, TiffType.short, 1, 1); // Compression: none
  tag(262, TiffType.short, 1, 2); // PhotometricInterpretation: RGB
  tag(273, TiffType.long, 1, pixelDataOffset); // StripOffsets
  tag(277, TiffType.short, 1, 4); // SamplesPerPixel
  tag(278, TiffType.long, 1, height); // RowsPerStrip
  tag(279, TiffType.long, 1, pixelDataLength); // StripByteCounts
  tag(282, TiffType.rational, 1, xResolutionOffset); // XResolution
  tag(283, TiffType.rational, 1, yResolutionOffset); // YResolution
  tag(284, TiffType.short, 1, 1); // PlanarConfiguration: chunky
  tag(296, TiffType.short, 1, 2); // ResolutionUnit: inch
  tag(338, TiffType.short, 1, 2); // ExtraSamples: unassociated alpha
  // The next-IFD offset after the entries stays 0: this is the only IFD.

  for (var i = 0; i < 4; i++) {
    view.setUint16(bitsPerSampleOffset + i * 2, 8, le);
  }
  view
    ..setUint32(xResolutionOffset, 72, le)
    ..setUint32(xResolutionOffset + 4, 1, le)
    ..setUint32(yResolutionOffset, 72, le)
    ..setUint32(yResolutionOffset + 4, 1, le);
  bytes.setRange(pixelDataOffset, fileLength, image.pixels);
  return bytes;
}
