/// Base class for every exception this package throws.
sealed class SvsException implements Exception {
  final String message;

  const SvsException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// The file is not a well-formed TIFF/BigTIFF, or violates a structural
/// invariant this reader relies on: bad header, an IFD chain cycle, tag
/// data that runs past end-of-file, a tile array whose length doesn't match
/// the level's tile grid, and similar corruption.
class SvsFormatException extends SvsException {
  const SvsFormatException(super.message);
}

/// A tile (or associated image) uses a compression scheme this package
/// cannot decode: JPEG2000, or old-style ("Compression" tag = 6) JPEG.
/// Detected deliberately and reported clearly rather than mis-decoded.
class SvsUnsupportedCompressionError extends SvsException {
  final int compressionTag;

  const SvsUnsupportedCompressionError(this.compressionTag, String message) : super(message);
}

/// Reading a specific tile failed at the I/O level (short read, file
/// disappeared, etc.) after the file itself had already been opened
/// successfully.
class TileIoException extends SvsException {
  final int level;
  final int tileX;
  final int tileY;

  const TileIoException(this.level, this.tileX, this.tileY, String message) : super(message);
}
