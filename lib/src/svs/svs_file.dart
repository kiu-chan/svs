import 'dart:typed_data';

import '../codec/background_codec.dart';
import '../codec/jpeg2000/j2k_decoder.dart';
import '../errors.dart';
import '../io/byte_source.dart';
import '../io/file_byte_source.dart';
import '../jpeg/jpeg_tables.dart';
import '../tiff/compression/tiff_decompress.dart';
import '../tiff/predictor.dart';
import '../tiff/raster.dart';
import '../tiff/tiff_file.dart';
import '../tiff/tiff_types.dart' show tilesAcross;
import 'aperio_tags.dart';
import 'svs_file_info.dart';
import 'svs_metadata.dart';

const _rawRasterCompressions = {
  ApCompression.none,
  ApCompression.lzw,
  ApCompression.deflate,
  ApCompression.packBits,
  ApCompression.deflateAdobe,
};

const _supportedLevelCompressions = {ApCompression.newJpeg, ApCompression.jp2k};

/// What a non-tiled [SvsAssociatedImage] embedded in an SVS file actually
/// shows — classified from its `ImageDescription`, since TIFF itself has no
/// tag for this.
enum AssociatedImageKind {
  /// The slide's physical label (barcode/handwritten ID), usually the small
  /// image printed on the slide itself.
  label,

  /// A gross ("macro") photo of the whole slide, including the label.
  macro,

  /// A scanner-generated low-resolution preview of the tissue — what
  /// [SvsImageView]'s minimap uses.
  thumbnail,
}

/// A non-tiled image embedded alongside the pyramid — the slide label,
/// a macro (gross) photo, or a scanner-generated thumbnail.
class SvsAssociatedImage {
  /// What this image shows, inferred from its `ImageDescription`.
  final AssociatedImageKind kind;

  /// Which IFD of the TIFF file this image is, counting from 0 — its
  /// identity within the file, and what [readAllTags] reports on.
  final int ifdIndex;

  /// The image's width in pixels.
  final int width;

  /// The image's height in pixels.
  final int height;

  /// TIFF `Compression` (259): see [ApCompression] for the values this
  /// package recognises.
  final int compression;

  /// TIFF `PhotometricInterpretation` (262): see [ApPhotometric].
  final int photometricInterpretation;

  /// TIFF `SamplesPerPixel` (277) — 3 for RGB, 4 with an alpha channel.
  final int samplesPerPixel;

  /// TIFF `BitsPerSample` (258), one entry per sample; this package decodes
  /// raw rasters only when every entry is 8.
  final List<int> bitsPerSample;

  /// TIFF `Predictor` (317): 1 for none, 2 for horizontal differencing.
  final int predictor;

  /// Whether this image uses new-style JPEG — decoded via [readStripJpegBytes]
  /// plus `dart:ui`'s own JPEG codec.
  bool get isJpeg => compression == ApCompression.newJpeg;

  /// Whether this image's JPEG strips need `forceRgbColorTransform` (in
  /// `jpeg/jpeg_tables.dart`) applied before decode — see that function's
  /// doc comment, and [SvsLevel.needsYCbCrFix] for the pyramid-tile
  /// equivalent of this same Aperio quirk.
  bool get needsYCbCrFix =>
      isJpeg && photometricInterpretation == ApPhotometric.rgb;

  /// False when this package can't decode this image's pixels. True for
  /// [isJpeg], and for the handled raw-raster compressions (LZW/PackBits/
  /// Deflate/none) *if* their sample layout is one this package understands
  /// (8-bit RGB or RGBA, horizontal-differencing predictor or none) — still
  /// listed rather than dropped when false, since the image's existence and
  /// dimensions are useful even when its pixels aren't decodable.
  bool get isDecodable {
    if (isJpeg) return true;
    if (!_rawRasterCompressions.contains(compression)) return false;
    if (photometricInterpretation != ApPhotometric.rgb) return false;
    if (samplesPerPixel != 3 && samplesPerPixel != 4) return false;
    if (bitsPerSample.any((b) => b != 8)) return false;
    if (predictor != 1 && predictor != 2) return false;
    return true;
  }

  final TiffFile _file;
  final TiffIfd _ifd;

  List<int>? _stripOffsets;
  List<int>? _stripByteCounts;
  int? _rowsPerStrip;
  Uint8List? _jpegTables;
  bool _jpegTablesLoaded = false;

  SvsAssociatedImage._({
    required this.kind,
    required this.ifdIndex,
    required this.width,
    required this.height,
    required this.compression,
    required this.photometricInterpretation,
    required this.samplesPerPixel,
    required this.bitsPerSample,
    required this.predictor,
    required this._file,
    required this._ifd,
  });

  Future<void> _ensureStripTablesLoaded() async {
    if (_stripOffsets != null) return;
    final offsets = await _ifd.readInts(ApTag.stripOffsets);
    final byteCounts = await _ifd.readInts(ApTag.stripByteCounts);
    if (offsets.length != byteCounts.length) {
      throw SvsFormatException(
        'Associated image (IFD $ifdIndex) has mismatched strip tables: '
        '${offsets.length} offsets vs ${byteCounts.length} byte counts',
      );
    }
    _stripOffsets = offsets;
    _stripByteCounts = byteCounts;
    // Absent RowsPerStrip means the whole image is one strip (TIFF default).
    _rowsPerStrip = _ifd.hasTag(ApTag.rowsPerStrip)
        ? await _ifd.readInt(ApTag.rowsPerStrip)
        : height;
  }

  Future<Uint8List?> _loadJpegTables() async {
    if (_jpegTablesLoaded) return _jpegTables;
    _jpegTablesLoaded = true;
    if (_ifd.hasTag(ApTag.jpegTables)) {
      _jpegTables = await _ifd.readRawBytes(ApTag.jpegTables);
    }
    return _jpegTables;
  }

  /// Number of independent JPEG strips this image is stored as. Non-tiled
  /// images are almost never a single contiguous JPEG — each strip covers
  /// up to [rowsPerStrip] rows and is its own standalone JPEG frame (sharing
  /// the file's JPEGTables), so a full decode means decoding every strip and
  /// compositing them, not concatenating their compressed bytes.
  Future<int> get stripCount async {
    await _ensureStripTablesLoaded();
    return _stripOffsets!.length;
  }

  /// Row span covered by every strip except possibly the last (which may be
  /// shorter, when [height] isn't a multiple of this).
  Future<int> get rowsPerStrip async {
    await _ensureStripTablesLoaded();
    return _rowsPerStrip!;
  }

  /// The spliced, standalone-decodable JPEG bytes for strip [i] alone —
  /// covering rows `[i * rowsPerStrip, min((i + 1) * rowsPerStrip, height))`
  /// of the image, with an Adobe `transform=0` marker inserted first (see
  /// [forceRgbColorTransform]) when [needsYCbCrFix]. Empty for a sparse
  /// strip (byte count 0 in the file).
  ///
  /// Throws [SvsUnsupportedCompressionError] if [isJpeg] is false — check
  /// that first (a non-JPEG image may still be decodable via
  /// [readStripRgba]).
  Future<Uint8List> readStripJpegBytes(int i) async {
    if (!isJpeg) {
      throw SvsUnsupportedCompressionError(
        compression,
        'Associated image (IFD $ifdIndex, $kind) uses TIFF Compression=$compression, not new-style '
        'JPEG (Compression=7) — use readStripRgba instead if isDecodable is true',
      );
    }

    await _ensureStripTablesLoaded();
    final byteCount = _stripByteCounts![i];
    if (byteCount == 0) return Uint8List(0);

    final raw = await _file.readBytes(_stripOffsets![i], byteCount);
    final tables = await _loadJpegTables();
    final spliced = spliceJpegTile(tables, raw);
    return needsYCbCrFix ? forceRgbColorTransform(spliced) : spliced;
  }

  /// The decoded RGBA8888 bytes for strip [i] alone, tightly packed — same
  /// row coverage as [readStripJpegBytes]. Empty for a sparse strip. Only
  /// for the raw-raster compressions (LZW/PackBits/Deflate/none); JPEG
  /// strips go through [readStripJpegBytes] instead.
  ///
  /// Throws [SvsUnsupportedCompressionError] if [isDecodable] is false —
  /// check that first to avoid the exception.
  Future<Uint8List> readStripRgba(int i) async {
    if (!isDecodable) {
      throw SvsUnsupportedCompressionError(
        compression,
        'Associated image (IFD $ifdIndex, $kind) uses TIFF Compression=$compression, '
        'PhotometricInterpretation=$photometricInterpretation, SamplesPerPixel=$samplesPerPixel, '
        'BitsPerSample=$bitsPerSample, Predictor=$predictor, which this package cannot decode',
      );
    }

    await _ensureStripTablesLoaded();
    final byteCount = _stripByteCounts![i];
    if (byteCount == 0) return Uint8List(0);

    final rows = _rowsInStrip(i);
    final raw = await _file.readBytes(_stripOffsets![i], byteCount);
    final samples = decompressTiffStrip(
      compression,
      raw,
      expectedLength: width * rows * samplesPerPixel,
    );
    if (predictor == 2) {
      undoHorizontalPredictor(
        samples,
        width: width,
        height: rows,
        samplesPerPixel: samplesPerPixel,
      );
    }
    return expandRgbToRgba(
      samples,
      width: width,
      height: rows,
      samplesPerPixel: samplesPerPixel,
    );
  }

  int _rowsInStrip(int i) {
    final remaining = height - i * _rowsPerStrip!;
    return remaining < _rowsPerStrip! ? remaining : _rowsPerStrip!;
  }

  /// Raw, still-compressed bytes for strip [i] exactly as stored in the
  /// source file — no `JPEGTables` splicing, no [needsYCbCrFix] patch, no
  /// decoding. Empty for a sparse strip (byte count 0). For a caller that
  /// wants to copy this image byte-for-byte into a new file (see
  /// `exportSvsRegionAsSvs` in `render/svs_pyramid_export.dart`) rather than
  /// decode it — paired with [jpegTables] and [readTags]/[readAllTags] for
  /// the other per-strip/per-IFD facts a faithful copy needs.
  Future<Uint8List> readRawStripBytes(int i) async {
    await _ensureStripTablesLoaded();
    final byteCount = _stripByteCounts![i];
    if (byteCount == 0) return Uint8List(0);
    return _file.readBytes(_stripOffsets![i], byteCount);
  }

  /// This image's raw `JPEGTables` bytes (the Huffman/quantization tables
  /// shared by every JPEG strip, spliced in by [readStripJpegBytes]), or
  /// null if the IFD carries none. Only meaningful when [isJpeg].
  Future<Uint8List?> get jpegTables => _loadJpegTables();

  /// This image's own `ImageDescription`, unparsed — the same text
  /// [SvsFile._classifyAssociatedImage] used to pick [kind]. A caller
  /// copying this image into a new file (see [readRawStripBytes]) needs to
  /// carry this forward verbatim, or a copied label/macro image would be
  /// reclassified as a bare thumbnail on reopen.
  Future<String?> get imageDescription =>
      _ifd.readAscii(ApTag.imageDescription);

  /// Every TIFF tag on this associated image's IFD, decoded — the "full
  /// info" dump for this image. See [TiffIfd.readAllValues].
  Future<Map<int, Object>> readAllTags() => _ifd.readAllValues();

  /// Just [ids] of this associated image's IFD tags, decoded — the
  /// "partial info" counterpart to [readAllTags].
  Future<Map<int, Object>> readTags(Iterable<int> ids) => _ifd.readValues(ids);
}

/// The pure geometric facts about one pyramid level, independent of whether
/// (or how) its tile bytes can actually be fetched — so viewport/LOD math
/// (see viewport_math.dart) can be unit-tested without opening any file.
class SvsLevelGeometry {
  /// This level's position in [SvsFile.levels], 0 being full resolution.
  final int index;

  /// The level's width in pixels.
  final int width;

  /// The level's height in pixels.
  final int height;

  /// The width of one tile in pixels; the rightmost column of tiles is
  /// padded out to it, so it may run past [width].
  final int tileWidth;

  /// The height of one tile in pixels (TIFF `TileLength`); the bottom row
  /// of tiles is padded out to it, so it may run past [height].
  final int tileLength;

  /// TIFF `Compression` (259) for this level's tiles: [ApCompression.newJpeg]
  /// or [ApCompression.jp2k] on the levels this package opens.
  final int compression;

  /// TIFF `PhotometricInterpretation` (262), or -1 if absent. Only
  /// meaningful for JPEG-compressed levels — see [SvsLevel.needsYCbCrFix].
  final int photometricInterpretation;

  /// `level0.width / width`. Real Aperio files are usually close to exact
  /// powers of 2 but this is computed, never assumed.
  final double downsample;

  /// Creates a level geometry from facts read off a TIFF directory, or
  /// made up in a test.
  const SvsLevelGeometry({
    required this.index,
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileLength,
    required this.compression,
    this.photometricInterpretation = -1,
    required this.downsample,
  });

  /// How many tiles wide this level's tile grid is, rounding up.
  int get tilesAcrossX => tilesAcross(width, tileWidth);

  /// How many tiles tall this level's tile grid is, rounding up.
  int get tilesAcrossY => tilesAcross(height, tileLength);
}

/// One level of the resolution pyramid: level 0 is full resolution, each
/// subsequent level is progressively downsampled. Tile tables and
/// JPEGTables are only read from disk the first time a tile is actually
/// requested from this level.
class SvsLevel {
  /// This level's size, tiling and scale, without the means to read it —
  /// the part viewport and LOD maths need.
  final SvsLevelGeometry geometry;

  /// See [SvsLevelGeometry.index].
  int get index => geometry.index;

  /// See [SvsLevelGeometry.width].
  int get width => geometry.width;

  /// See [SvsLevelGeometry.height].
  int get height => geometry.height;

  /// See [SvsLevelGeometry.tileWidth].
  int get tileWidth => geometry.tileWidth;

  /// See [SvsLevelGeometry.tileLength].
  int get tileLength => geometry.tileLength;

  /// See [SvsLevelGeometry.compression].
  int get compression => geometry.compression;

  /// See [SvsLevelGeometry.photometricInterpretation].
  int get photometricInterpretation => geometry.photometricInterpretation;

  /// See [SvsLevelGeometry.downsample].
  double get downsample => geometry.downsample;

  /// See [SvsLevelGeometry.tilesAcrossX].
  int get tilesAcrossX => geometry.tilesAcrossX;

  /// See [SvsLevelGeometry.tilesAcrossY].
  int get tilesAcrossY => geometry.tilesAcrossY;

  /// Whether this level's tiles are new-style JPEG, which
  /// [readTileJpegBytes] hands back ready to decode.
  bool get isJpeg => compression == ApCompression.newJpeg;

  /// Whether this level's tiles are JPEG2000, decoded by this package's own
  /// codec rather than the platform's.
  bool get isJp2k => compression == ApCompression.jp2k;

  /// Whether this level's JPEG tiles need `forceRgbColorTransform` (in
  /// `jpeg/jpeg_tables.dart`) applied before decode — see that function's
  /// doc comment for why. Only relevant when [isJpeg]; JP2K tiles go
  /// through this package's own decoder, which has no equivalent blind
  /// spot.
  bool get needsYCbCrFix =>
      isJpeg && photometricInterpretation == ApPhotometric.rgb;

  final TiffFile _file;
  final TiffIfd _ifd;

  List<int>? _tileOffsets;
  List<int>? _tileByteCounts;
  Uint8List? _jpegTables;
  bool _jpegTablesLoaded = false;

  SvsLevel._({required this.geometry, required this._file, required this._ifd});

  Future<void> _ensureTileTablesLoaded() async {
    if (_tileOffsets != null) return;
    final offsets = await _ifd.readInts(ApTag.tileOffsets);
    final byteCounts = await _ifd.readInts(ApTag.tileByteCounts);
    final expected = tilesAcrossX * tilesAcrossY;
    if (offsets.length != expected || byteCounts.length != expected) {
      throw SvsFormatException(
        'Level $index tile table length mismatch: expected $expected tiles '
        '(${tilesAcrossX}x$tilesAcrossY), got ${offsets.length} offsets / '
        '${byteCounts.length} byte counts',
      );
    }
    _tileOffsets = offsets;
    _tileByteCounts = byteCounts;
  }

  Future<Uint8List?> _loadJpegTables() async {
    if (_jpegTablesLoaded) return _jpegTables;
    _jpegTablesLoaded = true;
    if (_ifd.hasTag(ApTag.jpegTables)) {
      _jpegTables = await _ifd.readRawBytes(ApTag.jpegTables);
    }
    return _jpegTables;
  }

  /// Raw (still-compressed) bytes for tile ([tx], [ty]) straight off disk —
  /// empty for a sparse tile (byte count 0 in the file). Shared by
  /// [readTileJpegBytes] and [readTileRgba], which each interpret those
  /// bytes according to [compression].
  Future<Uint8List> _readRawTileBytes(int tx, int ty) async {
    await _ensureTileTablesLoaded();
    final tilesX = tilesAcrossX;
    final tilesY = tilesAcrossY;
    if (tx < 0 || tx >= tilesX || ty < 0 || ty >= tilesY) {
      throw SvsFormatException(
        'Tile ($tx,$ty) out of range for level $index (${tilesX}x$tilesY tiles)',
      );
    }

    final i = ty * tilesX + tx;
    final byteCount = _tileByteCounts![i];
    if (byteCount == 0) return Uint8List(0);

    final offset = _tileOffsets![i];
    return _file.readBytes(offset, byteCount);
  }

  /// The exact on-disk compressed byte size of tile ([tx], [ty]) — 0 for a
  /// sparse tile — without reading or decoding the tile itself. Useful for
  /// estimating this level's actual compression efficiency (e.g. an
  /// effective JPEG2000 ratio) from real tile sizes rather than assuming one.
  Future<int> tileByteCount(int tx, int ty) async {
    await _ensureTileTablesLoaded();
    final tilesX = tilesAcrossX;
    final tilesY = tilesAcrossY;
    if (tx < 0 || tx >= tilesX || ty < 0 || ty >= tilesY) {
      throw SvsFormatException(
        'Tile ($tx,$ty) out of range for level $index (${tilesX}x$tilesY tiles)',
      );
    }
    return _tileByteCounts![ty * tilesX + tx];
  }

  /// This level's own `ImageDescription`, unparsed — e.g.
  /// `Aperio Image Library v11.2.1\r\n...(256x256) JPEG/RGB Q=70|AppMag = 20|...`.
  /// Every level in a real Aperio file carries one, sized/worded for that
  /// level's own dimensions.
  Future<String?> get imageDescription =>
      _ifd.readAscii(ApTag.imageDescription);

  /// The spliced, standalone-decodable JPEG bytes for tile ([tx], [ty]) —
  /// with an Adobe `transform=0` marker inserted first (see
  /// [forceRgbColorTransform]) when [needsYCbCrFix]. Empty for a sparse
  /// tile — callers should treat that as blank rather than attempt to
  /// decode it. Only valid when [isJpeg]; use [readTileRgba] for [isJp2k]
  /// instead.
  Future<Uint8List> readTileJpegBytes(int tx, int ty) async {
    final rawTile = await _readRawTileBytes(tx, ty);
    if (rawTile.isEmpty) return rawTile;
    final tables = await _loadJpegTables();
    final spliced = spliceJpegTile(tables, rawTile);
    return needsYCbCrFix ? forceRgbColorTransform(spliced) : spliced;
  }

  /// The decoded RGBA8888 bytes for tile ([tx], [ty]), tightly packed —
  /// empty for a sparse tile. Only valid when [isJp2k]; use
  /// [readTileJpegBytes] for [isJpeg] instead.
  ///
  /// [reducedResolutionFactor] (default 0, full resolution) discards that
  /// many of the codestream's highest-resolution wavelet levels, decoding a
  /// `ceil(tileWidth / 2^f)` x `ceil(tileLength / 2^f)` tile — much faster
  /// and smaller when only a zoomed-out preview is needed. Throws
  /// [TileIoException] if the tile has fewer wavelet levels than that.
  ///
  /// Decoded by this package's own JPEG2000 decoder (pure Dart) — on the
  /// web, on a Web Worker; a malformed codestream throws
  /// [TileIoException].
  Future<Uint8List> readTileRgba(
    int tx,
    int ty, {
    int reducedResolutionFactor = 0,
  }) async {
    final rawTile = await _readRawTileBytes(tx, ty);
    if (rawTile.isEmpty) return rawTile;
    final J2kImage decoded;
    try {
      decoded = await decodeJ2kInBackground(
        rawTile,
        reducedResolutionFactor: reducedResolutionFactor,
      );
    } on J2kDecodeException catch (e) {
      throw TileIoException(
        index,
        tx,
        ty,
        'JPEG2000 decode failed: ${e.message}',
      );
    }
    return expandRgbToRgba(
      decoded.pixels,
      width: decoded.width,
      height: decoded.height,
      samplesPerPixel: decoded.numComponents,
    );
  }

  /// Every TIFF tag on this level's IFD, decoded — the "full info" dump for
  /// this level. See [TiffIfd.readAllValues].
  Future<Map<int, Object>> readAllTags() => _ifd.readAllValues();

  /// Just [ids] of this level's IFD tags, decoded — the "partial info"
  /// counterpart to [readAllTags].
  Future<Map<int, Object>> readTags(Iterable<int> ids) => _ifd.readValues(ids);
}

/// An open Aperio SVS file: the resolution pyramid, any associated images,
/// and the slide metadata parsed from level 0's `ImageDescription`.
///
/// v1 only supports SVS files whose pyramid tiles use standard ("new-style",
/// TIFF `Compression` = 7) JPEG — [open] throws [SvsUnsupportedCompressionError]
/// immediately for anything else (notably JPEG2000-compressed SVS), rather
/// than opening a file this package can list levels for but never actually
/// render.
class SvsFile {
  final TiffFile _tiff;

  /// The path this file was opened from, or null if it was opened via
  /// [openBytes] or [openSource]. Kept so a background isolate can reopen the same file
  /// independently (see `TileWorkerPool`) — a file handle can't be shared
  /// across isolates. When null, `TileWorkerPool` can't reopen this file, so
  /// tiles are fetched/decoded on the calling isolate instead (see
  /// `LodController`).
  final String? path;

  /// The resolution pyramid, finest first: `levels[0]` is full resolution
  /// and each one after it is more downsampled.
  final List<SvsLevel> levels;

  /// The non-tiled images stored alongside the pyramid — label, macro and
  /// thumbnail, in the order their IFDs appear.
  final List<SvsAssociatedImage> associatedImages;

  /// The slide's scanner metadata, parsed from the Aperio
  /// `ImageDescription` — magnification, microns per pixel, and the rest.
  final SvsMetadata metadata;

  SvsFile._({
    required this._tiff,
    required this.path,
    required this.levels,
    required this.associatedImages,
    required this.metadata,
  });

  /// Opens the slide at [path], reading only its TIFF directories — tiles
  /// are read later, as they are asked for.
  ///
  /// Not supported on the web, which has no paths; use [openBytes] or
  /// [openSource] there. Call [close] when finished with the slide.
  ///
  /// Throws an [SvsFormatException] if the file is not a TIFF this reader
  /// can make sense of.
  static Future<SvsFile> open(String path) async {
    final source = await openFileByteSource(path);
    final TiffFile tiff;
    try {
      tiff = await TiffFile.open(source);
    } catch (_) {
      await source.close();
      rethrow;
    }

    try {
      return await _fromTiff(tiff, path);
    } catch (_) {
      await tiff.close();
      rethrow;
    }
  }

  /// Opens a slide already fully in memory as [bytes] (e.g. from a network
  /// fetch). The returned [SvsFile.path] is null, since there's no
  /// reopenable filesystem path — see that field's doc comment for what that
  /// means for background tile fetching.
  ///
  /// This holds the whole slide in memory. To read only the parts actually
  /// needed instead — on the web, straight from a picked `File` — use
  /// [openSource].
  static Future<SvsFile> openBytes(Uint8List bytes) =>
      openSource(MemoryByteSource(bytes));

  /// Opens a slide from [source], reading only the byte ranges it needs: the
  /// TIFF directories up front, then each tile as it's requested. The way to
  /// view a slide larger than memory where there's no filesystem path to
  /// give [open] — on the web, `package:svs/svs_web.dart`'s `BlobByteSource`
  /// reads a picked or dropped `File` this way, and any other storage (e.g.
  /// HTTP `Range` requests) just needs its own [RandomAccessByteSource].
  ///
  /// The returned file owns [source]: [close] closes it, and so does this
  /// method if the slide fails to open. [path] is null, as for [openBytes].
  static Future<SvsFile> openSource(RandomAccessByteSource source) async {
    final TiffFile tiff;
    try {
      tiff = await TiffFile.open(source);
    } catch (_) {
      await source.close();
      rethrow;
    }

    try {
      return await _fromTiff(tiff, null);
    } catch (_) {
      await tiff.close();
      rethrow;
    }
  }

  static Future<SvsFile> _fromTiff(TiffFile tiff, String? path) async {
    if (tiff.ifds.isEmpty) {
      throw const SvsFormatException('File has no image directories');
    }

    final levels = <SvsLevel>[];
    final associated = <SvsAssociatedImage>[];
    var metadata = const SvsMetadata(raw: {});

    for (var i = 0; i < tiff.ifds.length; i++) {
      final ifd = tiff.ifds[i];
      final isTiled =
          ifd.hasTag(ApTag.tileWidth) && ifd.hasTag(ApTag.tileLength);
      final width = await ifd.readInt(ApTag.imageWidth);
      final height = await ifd.readInt(ApTag.imageLength);
      final description = await ifd.readAscii(ApTag.imageDescription);

      if (isTiled) {
        final compression = await ifd.readInt(
          ApTag.compression,
          fallback: ApCompression.newJpeg,
        );
        if (!_supportedLevelCompressions.contains(compression)) {
          throw SvsUnsupportedCompressionError(
            compression,
            'IFD $i (level ${levels.length}) uses TIFF Compression=$compression, which this '
            'package cannot decode — only new-style JPEG (Compression=7) and JPEG2000 '
            '(Compression=${ApCompression.jp2k}) are supported',
          );
        }
        final tileWidth = await ifd.readInt(ApTag.tileWidth);
        final tileLength = await ifd.readInt(ApTag.tileLength);
        final baseWidth = levels.isEmpty ? width : levels.first.width;
        levels.add(
          SvsLevel._(
            geometry: SvsLevelGeometry(
              index: levels.length,
              width: width,
              height: height,
              tileWidth: tileWidth,
              tileLength: tileLength,
              compression: compression,
              photometricInterpretation:
                  ifd.hasTag(ApTag.photometricInterpretation)
                  ? await ifd.readInt(ApTag.photometricInterpretation)
                  : -1,
              downsample: baseWidth / width,
            ),
            file: tiff,
            ifd: ifd,
          ),
        );
        if (levels.length == 1) {
          metadata = SvsMetadata.parse(description);
        }
      } else {
        final compression = await ifd.readInt(ApTag.compression, fallback: 0);
        associated.add(
          SvsAssociatedImage._(
            kind: _classifyAssociatedImage(description),
            ifdIndex: i,
            width: width,
            height: height,
            compression: compression,
            // TIFF defaults when these tags are absent: 1 sample/pixel, 1
            // bit/sample, Predictor=1 (none). PhotometricInterpretation has
            // no real default; -1 stands for "absent", which isDecodable
            // correctly treats as not-RGB.
            photometricInterpretation:
                ifd.hasTag(ApTag.photometricInterpretation)
                ? await ifd.readInt(ApTag.photometricInterpretation)
                : -1,
            samplesPerPixel: ifd.hasTag(ApTag.samplesPerPixel)
                ? await ifd.readInt(ApTag.samplesPerPixel)
                : 1,
            bitsPerSample: ifd.hasTag(ApTag.bitsPerSample)
                ? await ifd.readInts(ApTag.bitsPerSample)
                : const [1],
            predictor: ifd.hasTag(ApTag.predictor)
                ? await ifd.readInt(ApTag.predictor)
                : 1,
            file: tiff,
            ifd: ifd,
          ),
        );
      }
    }

    if (levels.isEmpty) {
      throw const SvsFormatException(
        'No tiled pyramid levels found — not a valid whole-slide TIFF',
      );
    }

    return SvsFile._(
      tiff: tiff,
      path: path,
      levels: levels,
      associatedImages: associated,
      metadata: metadata,
    );
  }

  static AssociatedImageKind _classifyAssociatedImage(String? description) {
    final d = description?.toLowerCase() ?? '';
    if (d.contains('macro')) return AssociatedImageKind.macro;
    if (d.contains('label')) return AssociatedImageKind.label;
    return AssociatedImageKind.thumbnail;
  }

  /// See [SvsLevel.readTileJpegBytes]; throws an [SvsFormatException] if
  /// [level] is not one this slide has.
  Future<Uint8List> readTileJpegBytes(int level, int tx, int ty) {
    if (level < 0 || level >= levels.length) {
      throw SvsFormatException(
        'Level $level out of range (have ${levels.length} levels)',
      );
    }
    return levels[level].readTileJpegBytes(tx, ty);
  }

  /// See [SvsLevel.readTileRgba].
  Future<Uint8List> readTileRgba(
    int level,
    int tx,
    int ty, {
    int reducedResolutionFactor = 0,
  }) {
    if (level < 0 || level >= levels.length) {
      throw SvsFormatException(
        'Level $level out of range (have ${levels.length} levels)',
      );
    }
    return levels[level].readTileRgba(
      tx,
      ty,
      reducedResolutionFactor: reducedResolutionFactor,
    );
  }

  /// Releases the slide's underlying byte source, and with it any file
  /// handle it holds. Reading from the file afterwards is an error.
  Future<void> close() => _tiff.close();

  /// A full structured dump of every TIFF tag on every pyramid level and
  /// associated image, plus this file's own container facts — the "full
  /// info" one-call counterpart to the narrower accessors already on this
  /// class ([levels], [associatedImages], [metadata]) and on [SvsLevel]/
  /// [SvsAssociatedImage] ([SvsLevel.readTags], [SvsAssociatedImage.readTags])
  /// for callers that only need specific fields.
  Future<SvsFileInfo> readInfo() async {
    final levelInfos = <SvsIfdInfo>[];
    for (final level in levels) {
      levelInfos.add(
        SvsIfdInfo(index: level.index, tags: await level.readAllTags()),
      );
    }
    final associatedInfos = <SvsIfdInfo>[];
    for (final image in associatedImages) {
      associatedInfos.add(
        SvsIfdInfo(index: image.ifdIndex, tags: await image.readAllTags()),
      );
    }
    return SvsFileInfo(
      path: path,
      isBigTiff: _tiff.header.kind == TiffKind.bigTiff,
      byteOrder: _tiff.header.byteOrder,
      metadata: metadata,
      levels: levelInfos,
      associatedImages: associatedInfos,
    );
  }
}
