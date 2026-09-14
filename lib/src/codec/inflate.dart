import 'dart:math' as math;
import 'dart:typed_data';

import 'deflate_tables.dart';
import 'huffman.dart';

/// Decodes a zlib-wrapped (RFC 1950) deflate stream in pure Dart — the web
/// implementation behind `zlib.dart`'s `zlibDecode` (native platforms use
/// `dart:io`'s zlib instead). The trailing Adler-32 checksum isn't verified.
///
/// Throws [FormatException] on a malformed or truncated stream.
Uint8List inflateZlib(Uint8List data) {
  if (data.length < 2) {
    throw const FormatException('zlib stream is too short');
  }
  final cmf = data[0];
  final flg = data[1];
  if ((cmf & 0x0f) != 8 || (cmf >> 4) > 7 || ((cmf << 8) | flg) % 31 != 0) {
    throw const FormatException('Not a zlib stream (bad header)');
  }
  if ((flg & 0x20) != 0) {
    throw const FormatException('zlib preset dictionaries are not supported');
  }
  return _Inflater(data, 2).inflate();
}

class _Inflater {
  final Uint8List _in;
  int _pos;
  int _bitBuffer = 0;
  int _bitCount = 0;
  Uint8List _out;
  int _outLength = 0;

  _Inflater(Uint8List input, int start)
    : _in = input,
      _pos = start,
      _out = Uint8List(math.max(1024, input.length * 4));

  Uint8List inflate() {
    var lastBlock = false;
    while (!lastBlock) {
      lastBlock = _bits(1) == 1;
      switch (_bits(2)) {
        case 0:
          _storedBlock();
        case 1:
          _huffmanBlock(_fixedLiteralTable, _fixedDistanceTable);
        case 2:
          final (literals, distances) = _readDynamicTables();
          _huffmanBlock(literals, distances);
        default:
          throw const FormatException('Invalid deflate block type');
      }
    }
    return _out.sublist(0, _outLength);
  }

  /// Reads [count] (at most 16) bits.
  int _bits(int count) {
    while (_bitCount < count) {
      if (_pos >= _in.length) throw _truncated();
      _bitBuffer |= _in[_pos++] << _bitCount;
      _bitCount += 8;
    }
    final value = _bitBuffer & ((1 << count) - 1);
    _bitBuffer >>= count;
    _bitCount -= count;
    _checkNotPastEnd();
    return value;
  }

  int _decodeSymbol(_HuffmanTable table) {
    // Peek a full table index's worth of bits. Near the end of the input
    // that can run past the last real byte, so missing bytes read as zero —
    // [_checkNotPastEnd] then rejects a code that actually consumed them.
    while (_bitCount < table.indexBits) {
      if (_pos < _in.length) _bitBuffer |= _in[_pos] << _bitCount;
      _pos++;
      _bitCount += 8;
    }
    final entry = table.entries[_bitBuffer & ((1 << table.indexBits) - 1)];
    final length = entry >> 9;
    if (length == 0) {
      throw const FormatException('Invalid Huffman code in deflate stream');
    }
    _bitBuffer >>= length;
    _bitCount -= length;
    _checkNotPastEnd();
    return entry & 0x1ff;
  }

  void _checkNotPastEnd() {
    if (_pos > _in.length && _bitCount < (_pos - _in.length) * 8) {
      throw _truncated();
    }
  }

  FormatException _truncated() =>
      const FormatException('Truncated deflate stream');

  void _storedBlock() {
    // Skip to a byte boundary, handing any whole bytes still buffered back
    // to the input.
    _pos -= _bitCount >> 3;
    _bitBuffer = 0;
    _bitCount = 0;
    if (_pos + 4 > _in.length) throw _truncated();
    final length = _in[_pos] | (_in[_pos + 1] << 8);
    final complement = _in[_pos + 2] | (_in[_pos + 3] << 8);
    if (length != (~complement & 0xffff)) {
      throw const FormatException('Corrupt stored deflate block');
    }
    _pos += 4;
    if (_pos + length > _in.length) throw _truncated();
    _reserve(length);
    _out.setRange(_outLength, _outLength + length, _in, _pos);
    _outLength += length;
    _pos += length;
  }

  (_HuffmanTable, _HuffmanTable) _readDynamicTables() {
    final literalCount = _bits(5) + 257;
    final distanceCount = _bits(5) + 1;
    final codeLengthCount = _bits(4) + 4;
    if (literalCount > 286 || distanceCount > 30) {
      throw const FormatException('Invalid dynamic deflate block header');
    }
    final codeLengthLengths = Uint8List(19);
    for (var i = 0; i < codeLengthCount; i++) {
      codeLengthLengths[deflateCodeLengthOrder[i]] = _bits(3);
    }
    final codeLengthTable = _HuffmanTable(codeLengthLengths);

    final lengths = Uint8List(literalCount + distanceCount);
    var i = 0;
    while (i < lengths.length) {
      final symbol = _decodeSymbol(codeLengthTable);
      if (symbol < 16) {
        lengths[i++] = symbol;
        continue;
      }
      var value = 0;
      final int repeat;
      if (symbol == 16) {
        if (i == 0) {
          throw const FormatException('Deflate length repeat with no previous');
        }
        value = lengths[i - 1];
        repeat = 3 + _bits(2);
      } else if (symbol == 17) {
        repeat = 3 + _bits(3);
      } else {
        repeat = 11 + _bits(7);
      }
      if (i + repeat > lengths.length) {
        throw const FormatException('Deflate code lengths overflow');
      }
      lengths.fillRange(i, i + repeat, value);
      i += repeat;
    }
    if (lengths[256] == 0) {
      throw const FormatException('Deflate block has no end-of-block code');
    }
    return (
      _HuffmanTable(Uint8List.sublistView(lengths, 0, literalCount)),
      _HuffmanTable(Uint8List.sublistView(lengths, literalCount)),
    );
  }

  void _huffmanBlock(_HuffmanTable literals, _HuffmanTable distances) {
    while (true) {
      final symbol = _decodeSymbol(literals);
      if (symbol < 256) {
        if (_outLength == _out.length) _reserve(1);
        _out[_outLength++] = symbol;
        continue;
      }
      if (symbol == 256) return;
      final lengthCode = symbol - 257;
      if (lengthCode >= deflateLengthBase.length) {
        throw const FormatException('Invalid deflate length code');
      }
      final length =
          deflateLengthBase[lengthCode] +
          _bits(deflateLengthExtraBits[lengthCode]);
      final distanceCode = _decodeSymbol(distances);
      if (distanceCode >= deflateDistanceBase.length) {
        throw const FormatException('Invalid deflate distance code');
      }
      final distance =
          deflateDistanceBase[distanceCode] +
          _bits(deflateDistanceExtraBits[distanceCode]);
      if (distance > _outLength) {
        throw const FormatException('Deflate distance reaches before start');
      }
      _reserve(length);
      var from = _outLength - distance;
      if (distance >= length) {
        _out.setRange(_outLength, _outLength + length, _out, from);
        _outLength += length;
      } else {
        // Overlapping copy: later bytes repeat ones this same copy writes.
        for (var k = 0; k < length; k++) {
          _out[_outLength++] = _out[from++];
        }
      }
    }
  }

  void _reserve(int count) {
    if (_outLength + count <= _out.length) return;
    final grown = Uint8List(math.max(_out.length * 2, _outLength + count));
    grown.setRange(0, _outLength, _out);
    _out = grown;
  }
}

/// A single-level lookup table for one Huffman code: indexed by the next
/// [indexBits] input bits (LSB-first), each entry packs the decoded symbol
/// (low 9 bits) and its code length (the bits above; 0 marks an unassigned
/// code).
class _HuffmanTable {
  final Uint16List entries;
  final int indexBits;

  _HuffmanTable._(this.entries, this.indexBits);

  factory _HuffmanTable(List<int> lengths) {
    var indexBits = 1;
    for (final length in lengths) {
      if (length > indexBits) indexBits = length;
    }
    var used = 0;
    for (final length in lengths) {
      if (length > 0) used += 1 << (indexBits - length);
    }
    if (used > (1 << indexBits)) {
      throw const FormatException('Over-subscribed Huffman code in deflate');
    }
    final entries = Uint16List(1 << indexBits);
    final codes = canonicalCodesLsb(lengths);
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length == 0) continue;
      final entry = (length << 9) | symbol;
      for (var i = codes[symbol]; i < entries.length; i += 1 << length) {
        entries[i] = entry;
      }
    }
    return _HuffmanTable._(entries, indexBits);
  }
}

final _fixedLiteralTable = _HuffmanTable(
  Uint8List(288)
    ..fillRange(0, 144, 8)
    ..fillRange(144, 256, 9)
    ..fillRange(256, 280, 7)
    ..fillRange(280, 288, 8),
);

final _fixedDistanceTable = _HuffmanTable(Uint8List(30)..fillRange(0, 30, 5));
