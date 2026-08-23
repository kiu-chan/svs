/// TIFF tag IDs this package reads. Standard baseline TIFF tags plus the
/// Aperio-specific use of ImageDescription — nothing here is SVS-only
/// except the values chosen for [ApCompression].
abstract final class ApTag {
  static const imageWidth = 256;
  static const imageLength = 257;
  static const bitsPerSample = 258;
  static const compression = 259;
  static const photometricInterpretation = 262;
  static const imageDescription = 270;
  static const stripOffsets = 273;
  static const samplesPerPixel = 277;
  static const rowsPerStrip = 278;
  static const stripByteCounts = 279;
  static const predictor = 317;
  static const tileWidth = 322;
  static const tileLength = 323;
  static const tileOffsets = 324;
  static const tileByteCounts = 325;
  static const jpegTables = 347;
}

/// TIFF `Compression` tag values this package understands. Pyramid levels
/// only ever use [newJpeg] or [jp2k] — everything else there is rejected
/// immediately (see `SvsFile._fromTiff`). Associated images (thumbnail/
/// label/macro) may legitimately use any of these; [oldJpeg] and unlisted
/// values are not decodable by this package (no old-style-JPEG decoder)
/// and are reported clearly rather than guessed at.
abstract final class ApCompression {
  static const none = 1;
  static const lzw = 5;
  static const oldJpeg = 6;
  static const newJpeg = 7;
  static const deflate = 8;

  /// JPEG2000, decoded via `openjpeg_ffi` (native OpenJPEG via FFI) rather
  /// than pure Dart — the one deliberate exception to this package's
  /// otherwise-pure-Dart rule. Empirically confirmed from real Aperio
  /// JP2K-compressed SVS files rather than cited from the baseline TIFF
  /// spec — this value appears to be an Aperio/vendor convention.
  static const jp2k = 33005;

  static const packBits = 32773;
  static const deflateAdobe = 32946;
}

/// TIFF `PhotometricInterpretation` values this package's raw-raster path
/// (LZW/PackBits/Deflate/none) supports. JPEG-compressed data doesn't need
/// this — the JPEG codec interprets its own YCbCr/RGB internally.
abstract final class ApPhotometric {
  static const rgb = 2;
}
