import 'dart:typed_data';

import '../../errors.dart';

const _clearCode = 256;
const _eoiCode = 257;
const _firstDataCode = 258;

/// Decodes a TIFF `Compression=5` (LZW) byte stream, per TIFF6 spec section
/// 13.
///
/// This is *not* the same bitstream as GIF's LZW: codes are packed MSB-first
/// (GIF is LSB-first), and the code width grows one code earlier than the
/// naive doubling point (511/1023/2047 instead of 512/1024/2048) — the
/// well-known TIFF "early change" quirk. Getting either wrong produces
/// garbage a few hundred bytes in, not a clean failure.
///
/// [expectedLength] is the known-good decompressed size (computed by the
/// caller from image geometry). The result is truncated or rejected against
/// it as a sanity check, since a corrupt stream can otherwise decode to a
/// plausible-looking but wrong-length buffer.
Uint8List decodeTiffLzw(Uint8List data, int expectedLength) {
  final dict = List<Uint8List>.generate(
    _firstDataCode,
    (i) => Uint8List.fromList([i]),
    growable: true,
  );
  var codeWidth = 9;
  Uint8List? oldEntry;

  var bitBuffer = 0;
  var bitCount = 0;
  var pos = 0;

  int? readCode() {
    while (bitCount < codeWidth) {
      if (pos >= data.length) return null;
      bitBuffer = (bitBuffer << 8) | data[pos++];
      bitCount += 8;
    }
    final code = (bitBuffer >> (bitCount - codeWidth)) & ((1 << codeWidth) - 1);
    bitCount -= codeWidth;
    return code;
  }

  final out = BytesBuilder();
  while (true) {
    final code = readCode();
    if (code == null || code == _eoiCode) break;

    if (code == _clearCode) {
      dict.length = _firstDataCode;
      codeWidth = 9;
      oldEntry = null;
      continue;
    }

    final Uint8List entry;
    if (code < dict.length) {
      entry = dict[code];
    } else if (code == dict.length && oldEntry != null) {
      entry = Uint8List.fromList([...oldEntry, oldEntry[0]]);
    } else {
      throw SvsFormatException(
        'Corrupt LZW stream: code $code is not valid at this point',
      );
    }
    out.add(entry);

    if (oldEntry != null) {
      dict.add(Uint8List.fromList([...oldEntry, entry[0]]));
      // "Early change": widen one code before the naive 512/1024/2048.
      if (dict.length == 511) {
        codeWidth = 10;
      } else if (dict.length == 1023) {
        codeWidth = 11;
      } else if (dict.length == 2047) {
        codeWidth = 12;
      } else if (dict.length >= 4094) {
        // A compliant encoder emits an explicit clear before overflowing the
        // 12-bit code space; this is a defensive fallback, not the norm.
        dict.length = _firstDataCode;
        codeWidth = 9;
        oldEntry = null;
        continue;
      }
    }
    oldEntry = entry;
  }

  final result = out.toBytes();
  if (result.length < expectedLength) {
    throw SvsFormatException(
      'Corrupt LZW stream: decoded ${result.length} bytes, expected $expectedLength',
    );
  }
  return result.length == expectedLength
      ? result
      : result.sublist(0, expectedLength);
}
