/// TIFF tag IDs this package reads. Standard baseline TIFF tags plus the
/// Aperio-specific use of ImageDescription — nothing here is SVS-only
/// except the values chosen for [ApCompression].
abstract final class ApTag {
  static const imageWidth = 256;
  static const imageLength = 257;
  static const compression = 259;
  static const imageDescription = 270;
  static const tileWidth = 322;
  static const tileLength = 323;
  static const tileOffsets = 324;
  static const tileByteCounts = 325;
  static const jpegTables = 347;
}

/// TIFF `Compression` tag values relevant to SVS. v1 of this package only
/// decodes [newJpeg] — every other value (old-style JPEG, JPEG2000, or
/// anything else) is rejected with [SvsUnsupportedCompressionError] rather
/// than guessed at, since no pure-Dart decoder exists for them.
abstract final class ApCompression {
  static const oldJpeg = 6;
  static const newJpeg = 7;
}
