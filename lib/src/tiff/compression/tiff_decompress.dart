import 'dart:typed_data';

import '../../errors.dart';
import '../../svs/aperio_tags.dart';
import 'deflate_decoder.dart';
import 'lzw_decoder.dart';
import 'packbits_decoder.dart';

/// Decompresses one strip's raw bytes to `expectedLength` bytes of raster
/// samples, dispatching on the TIFF `Compression` tag value. Covers every
/// [ApCompression] value that yields raw samples directly (not a JPEG
/// bitstream, which callers handle separately via the `jpeg/` splicing
/// path).
Uint8List decompressTiffStrip(
  int compression,
  Uint8List data, {
  required int expectedLength,
}) {
  switch (compression) {
    case ApCompression.none:
      if (data.length != expectedLength) {
        throw SvsFormatException(
          'Uncompressed strip has ${data.length} bytes, expected $expectedLength',
        );
      }
      return data;
    case ApCompression.lzw:
      return decodeTiffLzw(data, expectedLength);
    case ApCompression.packBits:
      return decodePackBits(data, expectedLength);
    case ApCompression.deflate:
    case ApCompression.deflateAdobe:
      final result = decodeTiffDeflate(data);
      if (result.length < expectedLength) {
        throw SvsFormatException(
          'Deflate stream decoded to ${result.length} bytes, expected $expectedLength',
        );
      }
      return result.length == expectedLength
          ? result
          : result.sublist(0, expectedLength);
    default:
      throw SvsUnsupportedCompressionError(
        compression,
        'Compression=$compression has no raw-raster decoder in this package',
      );
  }
}
