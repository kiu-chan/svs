/// Base class for every exception this package throws.
sealed class SvsException implements Exception {
  /// What went wrong, in a form fit to show a user or write to a log.
  final String message;

  /// Creates an exception carrying [message].
  const SvsException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// The file is not a well-formed TIFF/BigTIFF, or violates a structural
/// invariant this reader relies on: bad header, an IFD chain cycle, tag
/// data that runs past end-of-file, a tile array whose length doesn't match
/// the level's tile grid, and similar corruption.
class SvsFormatException extends SvsException {
  /// Creates a format exception describing the malformed structure.
  const SvsFormatException(super.message);
}

/// A tile (or associated image) uses a compression scheme this package
/// cannot decode: JPEG2000, or old-style ("Compression" tag = 6) JPEG.
/// Detected deliberately and reported clearly rather than mis-decoded.
class SvsUnsupportedCompressionError extends SvsException {
  /// The TIFF `Compression` tag value that was found, e.g. 6 for old-style
  /// JPEG.
  final int compressionTag;

  /// Creates the error for a tile compressed with [compressionTag].
  const SvsUnsupportedCompressionError(this.compressionTag, String message)
    : super(message);
}

/// Reading a specific tile failed at the I/O level (short read, file
/// disappeared, etc.) after the file itself had already been opened
/// successfully.
class TileIoException extends SvsException {
  /// The pyramid level the tile belongs to, 0 being full resolution.
  final int level;

  /// The tile's column in that level's tile grid.
  final int tileX;

  /// The tile's row in that level's tile grid.
  final int tileY;

  /// Creates the exception for the tile at [tileX], [tileY] of [level].
  const TileIoException(this.level, this.tileX, this.tileY, String message)
    : super(message);
}
