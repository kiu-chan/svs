import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_output.dart';
import 'deflate_tables.dart';
import 'huffman.dart';
import 'lsb_bit_writer.dart';

/// Compresses [data] into a zlib-wrapped (RFC 1950) deflate stream in pure
/// Dart — the web implementation behind `zlib.dart`'s `zlibEncode` (native
/// platforms use `dart:io`'s zlib instead).
///
/// Greedy LZ77 over hash chains, then one dynamic-Huffman block per 64K
/// symbols (or stored blocks, whenever those come out smaller): faster than
/// zlib's default level and a little larger, a fair trade for a fallback.
Uint8List deflateZlib(Uint8List data) {
  final out = ByteOutput(data.length ~/ 2 + 64);
  // CMF: deflate with a 32K window; FLG: default level, header check bits.
  out
    ..addByte(0x78)
    ..addByte(0x9c);
  final writer = LsbBitWriter(out);
  _Deflater(data, writer).run();
  writer.alignToByte();
  out.addUint32Be(adler32(data));
  return out.toBytes();
}

/// The Adler-32 checksum (RFC 1950 §9) of [data].
int adler32(Uint8List data) {
  const modulus = 65521;
  // The largest run that can't overflow 32 bits before reducing.
  const chunk = 5552;
  var a = 1;
  var b = 0;
  for (var start = 0; start < data.length; start += chunk) {
    final end = math.min(start + chunk, data.length);
    for (var i = start; i < end; i++) {
      a += data[i];
      b += a;
    }
    a %= modulus;
    b %= modulus;
  }
  return b * 65536 + a;
}

class _Deflater {
  static const _windowSize = 32768;
  static const _hashSize = 1 << 15;
  static const _minMatch = 3;
  static const _maxMatch = 258;
  static const _maxChainSteps = 32;
  static const _goodEnoughMatch = 128;
  static const _symbolsPerBlock = 1 << 16;

  final Uint8List _data;
  final LsbBitWriter _writer;
  final _head = Int32List(_hashSize)..fillRange(0, _hashSize, -1);
  final _previous = Int32List(_windowSize);

  /// This block's symbols: a literal byte (< 256), or a match packed as
  /// `(length << 16) | distance`.
  final _symbols = Int32List(_symbolsPerBlock);
  int _symbolCount = 0;
  final _literalCounts = Int32List(286);
  final _distanceCounts = Int32List(30);
  int _blockStart = 0;

  _Deflater(this._data, this._writer);

  void run() {
    final length = _data.length;
    var i = 0;
    while (i < length) {
      var bestLength = 0;
      var bestDistance = 0;
      if (i + _minMatch <= length) {
        final hash = _hash(i);
        final maxLength = math.min(_maxMatch, length - i);
        var candidate = _head[hash];
        var steps = _maxChainSteps;
        while (candidate >= 0 && i - candidate <= _windowSize && steps-- > 0) {
          if (_data[candidate + bestLength] == _data[i + bestLength]) {
            var matched = 0;
            while (matched < maxLength &&
                _data[candidate + matched] == _data[i + matched]) {
              matched++;
            }
            if (matched > bestLength) {
              bestLength = matched;
              bestDistance = i - candidate;
              if (matched >= _goodEnoughMatch || matched == maxLength) break;
            }
          }
          candidate = _previous[candidate & (_windowSize - 1)];
        }
        _insert(i, hash);
      }

      if (bestLength >= _minMatch) {
        _symbols[_symbolCount++] = (bestLength << 16) | bestDistance;
        _literalCounts[257 + _lengthCodes[bestLength]]++;
        _distanceCounts[_distanceCode(bestDistance)]++;
        final indexEnd = math.min(i + bestLength, length - _minMatch + 1);
        for (var k = i + 1; k < indexEnd; k++) {
          _insert(k, _hash(k));
        }
        i += bestLength;
      } else {
        _symbols[_symbolCount++] = _data[i];
        _literalCounts[_data[i]]++;
        i++;
      }
      if (_symbolCount == _symbolsPerBlock) _flushBlock(i, lastBlock: false);
    }
    _flushBlock(length, lastBlock: true);
  }

  int _hash(int i) =>
      ((_data[i] << 10) ^ (_data[i + 1] << 5) ^ _data[i + 2]) &
      (_hashSize - 1);

  void _insert(int position, int hash) {
    _previous[position & (_windowSize - 1)] = _head[hash];
    _head[hash] = position;
  }

  /// Writes the pending symbols — covering input `[_blockStart, end)` — as
  /// whichever of a dynamic-Huffman or stored block is smaller.
  void _flushBlock(int end, {required bool lastBlock}) {
    _literalCounts[256] = 1; // end-of-block
    final literalLengths = huffmanCodeLengths(
      _atLeastTwoUsed(_literalCounts),
      15,
    );
    final distanceLengths = huffmanCodeLengths(
      _atLeastTwoUsed(_distanceCounts),
      15,
    );
    var literalCount = 286;
    while (literalCount > 257 && literalLengths[literalCount - 1] == 0) {
      literalCount--;
    }
    var distanceCount = 30;
    while (distanceCount > 1 && distanceLengths[distanceCount - 1] == 0) {
      distanceCount--;
    }
    final codeLengthSymbols = runLengthEncodeCodeLengths([
      ...literalLengths.take(literalCount),
      ...distanceLengths.take(distanceCount),
    ]);
    final codeLengthCounts = List<int>.filled(19, 0);
    for (final entry in codeLengthSymbols) {
      codeLengthCounts[entry & 0xff]++;
    }
    final codeLengthLengths = huffmanCodeLengths(
      _atLeastTwoUsed(codeLengthCounts),
      7,
    );
    var codeLengthCount = 19;
    while (codeLengthCount > 4 &&
        codeLengthLengths[deflateCodeLengthOrder[codeLengthCount - 1]] == 0) {
      codeLengthCount--;
    }

    var dynamicBits = 3 + 5 + 5 + 4 + 3 * codeLengthCount;
    for (final entry in codeLengthSymbols) {
      final symbol = entry & 0xff;
      dynamicBits += codeLengthLengths[symbol] + codeLengthExtraBits(symbol);
    }
    for (var s = 0; s < 286; s++) {
      dynamicBits += _literalCounts[s] * literalLengths[s];
    }
    for (var c = 0; c < deflateLengthExtraBits.length; c++) {
      dynamicBits += _literalCounts[257 + c] * deflateLengthExtraBits[c];
    }
    for (var c = 0; c < 30; c++) {
      dynamicBits +=
          _distanceCounts[c] * (distanceLengths[c] + deflateDistanceExtraBits[c]);
    }
    final storedLength = end - _blockStart;
    final storedBlocks = math.max(1, (storedLength + 65534) ~/ 65535);
    // Per block: 3 header bits, up to 7 alignment bits, LEN and NLEN.
    final storedBits = storedBlocks * 42 + storedLength * 8;

    if (storedBits < dynamicBits) {
      _writeStoredBlocks(end, lastBlock: lastBlock);
    } else {
      _writer
        ..writeBits(lastBlock ? 1 : 0, 1)
        ..writeBits(2, 2)
        ..writeBits(literalCount - 257, 5)
        ..writeBits(distanceCount - 1, 5)
        ..writeBits(codeLengthCount - 4, 4);
      for (var i = 0; i < codeLengthCount; i++) {
        _writer.writeBits(codeLengthLengths[deflateCodeLengthOrder[i]], 3);
      }
      final codeLengthCodes = canonicalCodesLsb(codeLengthLengths);
      for (final entry in codeLengthSymbols) {
        final symbol = entry & 0xff;
        _writer.writeBits(codeLengthCodes[symbol], codeLengthLengths[symbol]);
        _writer.writeBits(entry >> 8, codeLengthExtraBits(symbol));
      }
      _writeSymbols(literalLengths, distanceLengths);
    }

    _symbolCount = 0;
    _literalCounts.fillRange(0, _literalCounts.length, 0);
    _distanceCounts.fillRange(0, _distanceCounts.length, 0);
    _blockStart = end;
  }

  void _writeSymbols(Uint8List literalLengths, Uint8List distanceLengths) {
    final literalCodes = canonicalCodesLsb(literalLengths);
    final distanceCodes = canonicalCodesLsb(distanceLengths);
    for (var k = 0; k < _symbolCount; k++) {
      final symbol = _symbols[k];
      if (symbol < 256) {
        _writer.writeBits(literalCodes[symbol], literalLengths[symbol]);
        continue;
      }
      final length = symbol >> 16;
      final distance = symbol & 0xffff;
      final lengthCode = _lengthCodes[length];
      _writer
        ..writeBits(literalCodes[257 + lengthCode], literalLengths[257 + lengthCode])
        ..writeBits(
          length - deflateLengthBase[lengthCode],
          deflateLengthExtraBits[lengthCode],
        );
      final distanceCode = _distanceCode(distance);
      _writer
        ..writeBits(distanceCodes[distanceCode], distanceLengths[distanceCode])
        ..writeBits(
          distance - deflateDistanceBase[distanceCode],
          deflateDistanceExtraBits[distanceCode],
        );
    }
    _writer.writeBits(literalCodes[256], literalLengths[256]);
  }

  void _writeStoredBlocks(int end, {required bool lastBlock}) {
    var start = _blockStart;
    do {
      final length = math.min(65535, end - start);
      _writer
        ..writeBits(lastBlock && start + length == end ? 1 : 0, 1)
        ..writeBits(0, 2)
        ..alignToByte()
        ..writeBits(length, 16)
        ..writeBits(~length & 0xffff, 16)
        ..writeAlignedBytes(_data, start, start + length);
      start += length;
    } while (start < end);
  }
}

/// A copy of [counts] with dummy counts added until at least two symbols are
/// used — zlib rejects the incomplete one-symbol codes a Huffman builder
/// would otherwise produce for a nearly empty block.
List<int> _atLeastTwoUsed(List<int> counts) {
  final copy = List<int>.of(counts);
  var used = copy.where((c) => c > 0).length;
  for (var s = 0; used < 2; s++) {
    if (copy[s] == 0) {
      copy[s] = 1;
      used++;
    }
  }
  return copy;
}

/// Length code (0-28, i.e. symbol minus 257) for each match length 3-258.
final _lengthCodes = () {
  final codes = Uint8List(259);
  for (var code = 0; code < deflateLengthBase.length; code++) {
    final base = deflateLengthBase[code];
    final end = math.min(259, base + (1 << deflateLengthExtraBits[code]));
    // Code 28 (length 258) runs last and so overrides code 27's range end.
    codes.fillRange(base, end, code);
  }
  return codes;
}();

int _distanceCode(int distance) {
  if (distance <= 4) return distance - 1;
  final n = distance - 1;
  final highBit = n.bitLength - 1;
  return 2 * highBit + ((n >> (highBit - 1)) & 1);
}
