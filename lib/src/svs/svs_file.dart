import 'dart:io';
import 'dart:typed_data';

import 'package:openjpeg_ffi/openjpeg_ffi.dart';

import '../errors.dart';
import '../jpeg/jpeg_tables.dart';
import '../tiff/compression/tiff_decompress.dart';
import '../tiff/predictor.dart';
import '../tiff/raster.dart';
import '../tiff/tiff_file.dart';
import 'aperio_tags.dart';
import 'svs_metadata.dart';

const _rawRasterCompressions = {
  ApCompression.none,
  ApCompression.lzw,
  ApCompression.deflate,
  ApCompression.packBits,
  ApCompression.deflateAdobe,
};

const _supportedLevelCompressions = {ApCompression.newJpeg, ApCompression.jp2k};

enum AssociatedImageKind { label, macro, thumbnail }

/// A non-tiled image embedded alongside the pyramid — the slide label,
/// a macro (gross) photo, or a scanner-generated thumbnail.
class SvsAssociatedImage {
  final AssociatedImageKind kind;
  final int ifdIndex;
  final int width;
  final int height;
  final int compression;
  final int photometricInterpretation;
  final int samplesPerPixel;
  final List<int> bitsPerSample;
  final int predictor;

  /// Whether this image uses new-style JPEG — decoded via [readStripJpegBytes]
  /// plus `dart:ui`'s own JPEG codec.
  bool get isJpeg => compression == ApCompression.newJpeg;

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
  /// of the image. Empty for a sparse strip (byte count 0 in the file).
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
    return spliceJpegTile(tables, raw);
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
}

/// The pure geometric facts about one pyramid level, independent of whether
/// (or how) its tile bytes can actually be fetched — so viewport/LOD math
/// (see viewport_math.dart) can be unit-tested without opening any file.
class SvsLevelGeometry {
  final int index;
  final int width;
  final int height;
  final int tileWidth;
  final int tileLength;
  final int compression;

  /// TIFF `PhotometricInterpretation` (262), or -1 if absent. Only
  /// meaningful for JPEG-compressed levels — see [SvsLevel.needsYCbCrFix].
  final int photometricInterpretation;

  /// `level0.width / width`. Real Aperio files are usually close to exact
  /// powers of 2 but this is computed, never assumed.
  final double downsample;

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

  int get tilesAcrossX => (width / tileWidth).ceil();
  int get tilesAcrossY => (height / tileLength).ceil();
}

/// One level of the resolution pyramid: level 0 is full resolution, each
/// subsequent level is progressively downsampled. Tile tables and
/// JPEGTables are only read from disk the first time a tile is actually
/// requested from this level.
class SvsLevel {
  final SvsLevelGeometry geometry;

  int get index => geometry.index;
  int get width => geometry.width;
  int get height => geometry.height;
  int get tileWidth => geometry.tileWidth;
  int get tileLength => geometry.tileLength;
  int get compression => geometry.compression;
  int get photometricInterpretation => geometry.photometricInterpretation;
  double get downsample => geometry.downsample;
  int get tilesAcrossX => geometry.tilesAcrossX;
  int get tilesAcrossY => geometry.tilesAcrossY;

  bool get isJpeg => compression == ApCompression.newJpeg;
  bool get isJp2k => compression == ApCompression.jp2k;

  /// Whether this level's JPEG tiles need `undoSpuriousYCbCr` (in
  /// `render/ycbcr_fix.dart`) applied after decode — see that function's doc
  /// comment for why. Only relevant when
  /// [isJpeg]; JP2K tiles are decoded by `openjpeg_ffi`, which has no
  /// equivalent blind spot.
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

  /// The spliced, standalone-decodable JPEG bytes for tile ([tx], [ty]).
  /// Empty for a sparse tile — callers should treat that as blank rather
  /// than attempt to decode it. Only valid when [isJpeg]; use
  /// [readTileRgba] for [isJp2k] instead.
  Future<Uint8List> readTileJpegBytes(int tx, int ty) async {
    final rawTile = await _readRawTileBytes(tx, ty);
    if (rawTile.isEmpty) return rawTile;
    final tables = await _loadJpegTables();
    return spliceJpegTile(tables, rawTile);
  }

  /// The decoded RGBA8888 bytes for tile ([tx], [ty]), tightly packed —
  /// empty for a sparse tile. Only valid when [isJp2k]; use
  /// [readTileJpegBytes] for [isJpeg] instead.
  ///
  /// Decoding happens via `openjpeg_ffi` (native OpenJPEG) — see
  /// [Jp2kDecodeException] for how decode failures surface.
  Future<Uint8List> readTileRgba(int tx, int ty) async {
    final rawTile = await _readRawTileBytes(tx, ty);
    if (rawTile.isEmpty) return rawTile;
    final Jp2kImage decoded;
    try {
      decoded = decodeJ2k(rawTile);
    } on Jp2kDecodeException catch (e) {
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

  /// The path this file was opened from. Kept so a background isolate can
  /// reopen the same file independently (see `TileWorkerPool`) — a
  /// `RandomAccessFile` handle can't be shared across isolates.
  final String path;
  final List<SvsLevel> levels;
  final List<SvsAssociatedImage> associatedImages;
  final SvsMetadata metadata;

  SvsFile._({
    required this._tiff,
    required this.path,
    required this.levels,
    required this.associatedImages,
    required this.metadata,
  });

  static Future<SvsFile> open(String path) async {
    final raf = await File(path).open(mode: FileMode.read);
    final TiffFile tiff;
    try {
      tiff = await TiffFile.open(raf);
    } catch (_) {
      await raf.close();
      rethrow;
    }

    try {
      return await _fromTiff(tiff, path);
    } catch (_) {
      await tiff.close();
      rethrow;
    }
  }

  static Future<SvsFile> _fromTiff(TiffFile tiff, String path) async {
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

  Future<Uint8List> readTileJpegBytes(int level, int tx, int ty) {
    if (level < 0 || level >= levels.length) {
      throw SvsFormatException(
        'Level $level out of range (have ${levels.length} levels)',
      );
    }
    return levels[level].readTileJpegBytes(tx, ty);
  }

  Future<Uint8List> readTileRgba(int level, int tx, int ty) {
    if (level < 0 || level >= levels.length) {
      throw SvsFormatException(
        'Level $level out of range (have ${levels.length} levels)',
      );
    }
    return levels[level].readTileRgba(tx, ty);
  }

  Future<void> close() => _tiff.close();
}
