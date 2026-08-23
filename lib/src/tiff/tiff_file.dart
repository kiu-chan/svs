import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';
import 'tiff_types.dart';

/// A file uses either classic TIFF (32-bit offsets, header magic 42) or
/// BigTIFF (64-bit offsets, magic 43). Large whole-slide images frequently
/// need BigTIFF, so this reader supports both.
enum TiffKind { classic, bigTiff }

class TiffHeader {
  final Endian byteOrder;
  final TiffKind kind;
  final int firstIfdOffset;

  const TiffHeader({required this.byteOrder, required this.kind, required this.firstIfdOffset});

  /// Size in bytes of any offset/value field for this file: the per-entry
  /// "value or offset" sub-field, and the next-IFD pointer.
  int get valueFieldSize => kind == TiffKind.bigTiff ? 8 : 4;
}

/// One field of a directory entry, resolved just enough to be read on
/// demand: the raw "value or offset" bytes are captured while walking the
/// IFD (cheap — already in hand), but out-of-line data (e.g. a TileOffsets
/// array with ~10^5 entries) is only fetched when a caller actually asks
/// for it via [TiffIfd.readInts] etc.
class TiffTag {
  final int id;
  final int type;
  final int count;
  final Uint8List valueField;

  const TiffTag({required this.id, required this.type, required this.count, required this.valueField});

  int get totalBytes => count * tiffTypeSize(type);
}

class TiffIfd {
  final int offset;
  final Map<int, TiffTag> tags;
  final int? nextIfdOffset;
  final TiffFile _file;

  const TiffIfd._({required this.offset, required this.tags, required this.nextIfdOffset, required TiffFile file})
    : _file = file;

  bool hasTag(int id) => tags.containsKey(id);

  TiffTag? tag(int id) => tags[id];

  Future<Uint8List> _resolveValueBytes(TiffTag t) async {
    final inlineSize = _file.header.valueFieldSize;
    if (t.totalBytes <= inlineSize) {
      return Uint8List.sublistView(t.valueField, 0, t.totalBytes);
    }
    final data = ByteData.sublistView(t.valueField);
    final offset = _file.header.kind == TiffKind.bigTiff
        ? data.getUint64(0, _file.header.byteOrder)
        : data.getUint32(0, _file.header.byteOrder);
    return _file.readBytes(offset, t.totalBytes);
  }

  TiffTag _require(int id) {
    final t = tags[id];
    if (t == null) {
      throw SvsFormatException('Tag $id not present in IFD at offset $offset');
    }
    return t;
  }

  /// All integer values of tag [id] (works for BYTE/SHORT/LONG/LONG8 and
  /// their signed variants), fetching out-of-line data if needed.
  Future<List<int>> readInts(int id) async {
    final t = _require(id);
    final bytes = await _resolveValueBytes(t);
    return decodeTiffInts(bytes, t.type, t.count, _file.header.byteOrder);
  }

  /// The first (typically only) integer value of tag [id]. Returns
  /// [fallback] if the tag is absent and a fallback was given, else throws.
  Future<int> readInt(int id, {int? fallback}) async {
    if (!hasTag(id)) {
      if (fallback != null) return fallback;
      throw SvsFormatException('Tag $id not present in IFD at offset $offset');
    }
    final values = await readInts(id);
    if (values.isEmpty) {
      throw SvsFormatException('Tag $id in IFD at offset $offset has no values');
    }
    return values.first;
  }

  /// The decoded ASCII value of tag [id], or null if the tag is absent.
  Future<String?> readAscii(int id) async {
    final t = tags[id];
    if (t == null) return null;
    if (t.type != TiffType.ascii) {
      throw SvsFormatException('Tag $id in IFD at offset $offset is not ASCII (type=${t.type})');
    }
    final bytes = await _resolveValueBytes(t);
    return decodeTiffAscii(bytes);
  }

  /// The raw undecoded bytes of tag [id] (e.g. JPEGTables, an UNDEFINED
  /// field).
  Future<Uint8List> readRawBytes(int id) async {
    final t = _require(id);
    return _resolveValueBytes(t);
  }
}

/// A random-access reader for one TIFF/BigTIFF file: parses the header and
/// walks the IFD chain up front, but never eagerly reads large out-of-line
/// tag arrays (tile offset/byte-count tables) — those are read lazily, only
/// for the level a caller actually opens.
class TiffFile {
  static const _maxIfdChainLength = 1000;

  final RandomAccessFile _raf;
  final TiffHeader header;
  final List<TiffIfd> ifds;

  // Serializes access to `_raf`: `setPosition` then `read` is two separate
  // awaits on one shared file handle, so concurrent callers (e.g. many
  // tiles requested at once while panning/zooming) can interleave their
  // setPosition/read pairs and silently read each other's bytes at the
  // wrong offset. Every read is chained onto this to force one in flight
  // at a time.
  Future<void> _readQueue = Future.value();

  TiffFile._(this._raf, this.header, this.ifds);

  static Future<TiffFile> open(RandomAccessFile raf) async {
    final header = await _readHeader(raf);
    final ifds = <TiffIfd>[];
    final file = TiffFile._(raf, header, ifds);

    final visited = <int>{};
    var offset = header.firstIfdOffset;
    while (offset != 0) {
      if (!visited.add(offset)) {
        throw SvsFormatException('IFD chain contains a cycle back to offset $offset');
      }
      if (visited.length > _maxIfdChainLength) {
        throw SvsFormatException('IFD chain exceeds $_maxIfdChainLength entries — likely corrupt');
      }
      final ifd = await _readIfd(file, offset);
      ifds.add(ifd);
      offset = ifd.nextIfdOffset ?? 0;
    }
    return file;
  }

  Future<Uint8List> readBytes(int offset, int length) {
    if (length == 0) return Future.value(Uint8List(0));
    final result = _readQueue.then((_) => _readBytesUnlocked(offset, length));
    // Keep the queue moving even if this read failed — swallow the error
    // here (it still propagates to the caller via `result`) so one bad
    // read doesn't wedge every read after it.
    _readQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Uint8List> _readBytesUnlocked(int offset, int length) async {
    await _raf.setPosition(offset);
    final bytes = await _raf.read(length);
    if (bytes.length != length) {
      throw SvsFormatException(
        'Unexpected end of file: wanted $length bytes at offset $offset, got ${bytes.length}',
      );
    }
    return bytes;
  }

  Future<void> close() => _raf.close();

  static Future<TiffHeader> _readHeader(RandomAccessFile raf) async {
    await raf.setPosition(0);
    final bytes = await raf.read(16);
    if (bytes.length < 8) {
      throw const SvsFormatException('File too short to contain a TIFF header');
    }

    final Endian order;
    if (bytes[0] == 0x49 && bytes[1] == 0x49) {
      order = Endian.little;
    } else if (bytes[0] == 0x4D && bytes[1] == 0x4D) {
      order = Endian.big;
    } else {
      throw const SvsFormatException('Not a TIFF file: bad byte-order marker');
    }

    final data = ByteData.sublistView(bytes);
    final magic = data.getUint16(2, order);
    if (magic == 42) {
      final firstIfd = data.getUint32(4, order);
      return TiffHeader(byteOrder: order, kind: TiffKind.classic, firstIfdOffset: firstIfd);
    }
    if (magic == 43) {
      if (bytes.length < 16) {
        throw const SvsFormatException('File too short to contain a BigTIFF header');
      }
      final offsetByteSize = data.getUint16(4, order);
      if (offsetByteSize != 8) {
        throw SvsFormatException('Unsupported BigTIFF offset size: $offsetByteSize');
      }
      final firstIfd = data.getUint64(8, order);
      return TiffHeader(byteOrder: order, kind: TiffKind.bigTiff, firstIfdOffset: firstIfd);
    }
    throw SvsFormatException('Unrecognized TIFF magic number: $magic');
  }

  static Future<TiffIfd> _readIfd(TiffFile file, int offset) async {
    final order = file.header.byteOrder;
    final isBig = file.header.kind == TiffKind.bigTiff;

    final dirCountFieldSize = isBig ? 8 : 2; // "number of directory entries"
    final entrySize = isBig ? 20 : 12; // one directory entry
    final entryCountFieldSize = isBig ? 8 : 4; // per-entry "count" sub-field
    final valueFieldSize = file.header.valueFieldSize; // per-entry "value or offset" sub-field
    const entryCountFieldOffset = 4; // id(2) + type(2) precede it, in both kinds
    final valueFieldOffset = entryCountFieldOffset + entryCountFieldSize;

    final dirCountBytes = await file.readBytes(offset, dirCountFieldSize);
    final dirCountData = ByteData.sublistView(dirCountBytes);
    final entryCount = isBig ? dirCountData.getUint64(0, order) : dirCountData.getUint16(0, order);

    final tableStart = offset + dirCountFieldSize;
    final tableBytes = await file.readBytes(tableStart, entryCount * entrySize);
    final tableData = ByteData.sublistView(tableBytes);

    final tags = <int, TiffTag>{};
    for (var i = 0; i < entryCount; i++) {
      final base = i * entrySize;
      final id = tableData.getUint16(base, order);
      final type = tableData.getUint16(base + 2, order);
      final count = isBig
          ? tableData.getUint64(base + entryCountFieldOffset, order)
          : tableData.getUint32(base + entryCountFieldOffset, order);
      final vOff = base + valueFieldOffset;
      final valueField = Uint8List.sublistView(tableBytes, vOff, vOff + valueFieldSize);
      tags[id] = TiffTag(id: id, type: type, count: count, valueField: valueField);
    }

    final nextOffsetPos = tableStart + entryCount * entrySize;
    final nextBytes = await file.readBytes(nextOffsetPos, valueFieldSize);
    final nextData = ByteData.sublistView(nextBytes);
    final next = isBig ? nextData.getUint64(0, order) : nextData.getUint32(0, order);

    return TiffIfd._(offset: offset, tags: tags, nextIfdOffset: next == 0 ? null : next, file: file);
  }
}
