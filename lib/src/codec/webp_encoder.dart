import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_output.dart';
import 'huffman.dart';
import 'lsb_bit_writer.dart';
import 'rgba_image.dart';

/// Largest width/height libwebp accepts (`WEBP_MAX_DIMENSION`).
const _maxDimension = 16383;

const _predictorTransform = 0;
const _subtractGreenTransform = 2;

/// Predictor modes are chosen per 2^4 = 16px square block.
const _predictorBlockBits = 4;

/// The predictor modes (of VP8L's 14) tried for each block — the ones that
/// pay off most on photographic content.
const _candidateModes = [1, 2, 7, 11, 12, 13];

/// Shortest run of repeated pixels worth a back-reference over literals.
const _minCopyLength = 4;

/// Longest back-reference VP8L can express.
const _maxCopyLength = 4096;

/// VP8L plane codes (entries of its 2-D distance map, 1-based) for the only
/// two back-reference sources this encoder uses.
const _planeCodeAbove = 1;
const _planeCodeLeft = 2;

/// Order a normal prefix code lists its code-length code's lengths in.
const _codeLengthOrder = [
  17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
];

/// Encodes [image] as a lossless WebP: a VP8L bitstream in a RIFF container.
///
/// Uses a small subset of what VP8L allows — the subtract-green transform, a
/// predictor transform chosen per 16x16 block, and back-references that
/// repeat the pixel to the left or above; no color cache, color-indexing or
/// meta prefix codes. Files come out larger than libwebp's, but decode
/// losslessly with any conforming decoder.
Uint8List encodeWebP(RgbaImage image) {
  final width = image.width;
  final height = image.height;
  if (width < 1 ||
      height < 1 ||
      width > _maxDimension ||
      height > _maxDimension) {
    throw ArgumentError(
      'WebP dimensions must be 1-$_maxDimension px per side, '
      'got ${width}x$height',
    );
  }

  // The subtract-green transform, applied up front: red and blue become
  // offsets from green.
  final pixelCount = width * height;
  final planes = _Planes(pixelCount);
  final pixels = image.pixels;
  var hasAlpha = false;
  for (var i = 0, p = 0; i < pixelCount; i++, p += 4) {
    final green = pixels[p + 1];
    planes.g[i] = green;
    planes.r[i] = (pixels[p] - green) & 0xff;
    planes.b[i] = (pixels[p + 2] - green) & 0xff;
    planes.a[i] = pixels[p + 3];
    if (pixels[p + 3] != 255) hasAlpha = true;
  }

  final blocksX = _blockCount(width);
  final blocksY = _blockCount(height);
  final modes = _selectPredictorModes(planes, width, height, blocksX, blocksY);
  final residuals = _predictorResiduals(planes, width, height, modes, blocksX);
  final modeImage = _Planes(modes.length);
  for (var i = 0; i < modes.length; i++) {
    modeImage.a[i] = 255;
    modeImage.g[i] = modes[i];
  }

  final data = ByteOutput(pixelCount + 64);
  final writer = LsbBitWriter(data)
    ..writeBits(0x2f, 8) // VP8L signature
    ..writeBits(width - 1, 14)
    ..writeBits(height - 1, 14)
    ..writeBits(hasAlpha ? 1 : 0, 1)
    ..writeBits(0, 3) // version
    // Transforms in the order they were applied; decoders undo them in
    // reverse.
    ..writeBits(1, 1)
    ..writeBits(_subtractGreenTransform, 2)
    ..writeBits(1, 1)
    ..writeBits(_predictorTransform, 2)
    ..writeBits(_predictorBlockBits - 2, 3);
  _writeEntropyCodedImage(writer, modeImage, blocksX, isMainImage: false);
  writer.writeBits(0, 1); // no more transforms
  _writeEntropyCodedImage(writer, residuals, width, isMainImage: true);
  writer.alignToByte();
  final vp8l = data.toBytes();

  final padding = vp8l.length & 1;
  final riff = ByteOutput(vp8l.length + 21)
    ..addBytes('RIFF'.codeUnits)
    ..addUint32Le(4 + 8 + vp8l.length + padding)
    ..addBytes('WEBP'.codeUnits)
    ..addBytes('VP8L'.codeUnits)
    ..addUint32Le(vp8l.length)
    ..addBytes(vp8l);
  if (padding == 1) riff.addByte(0);
  return riff.toBytes();
}

/// One plane per ARGB channel.
class _Planes {
  final Uint8List a, r, g, b;

  _Planes(int length)
    : a = Uint8List(length),
      r = Uint8List(length),
      g = Uint8List(length),
      b = Uint8List(length);

  bool samePixel(int i, int j) =>
      g[i] == g[j] && r[i] == r[j] && b[i] == b[j] && a[i] == a[j];
}

int _blockCount(int size) =>
    (size + (1 << _predictorBlockBits) - 1) >> _predictorBlockBits;

/// For each block, the candidate mode with the smallest total residual
/// magnitude.
Uint8List _selectPredictorModes(
  _Planes planes,
  int width,
  int height,
  int blocksX,
  int blocksY,
) {
  const blockSize = 1 << _predictorBlockBits;
  final modes = Uint8List(blocksX * blocksY);
  final prediction = Int32List(4);
  for (var by = 0; by < blocksY; by++) {
    // Row 0 and column 0 are predicted the same way whatever the block's
    // mode, so they don't take part in choosing it.
    final top = math.max(1, by * blockSize);
    final bottom = math.min(height, (by + 1) * blockSize);
    for (var bx = 0; bx < blocksX; bx++) {
      final left = math.max(1, bx * blockSize);
      final right = math.min(width, (bx + 1) * blockSize);
      var bestMode = _candidateModes.first;
      var bestCost = -1;
      for (final mode in _candidateModes) {
        var cost = 0;
        for (var y = top; y < bottom; y++) {
          for (var x = left; x < right; x++) {
            final i = y * width + x;
            _predict(mode, planes, i, width, prediction);
            cost +=
                _magnitude(planes.a[i] - prediction[0]) +
                _magnitude(planes.r[i] - prediction[1]) +
                _magnitude(planes.g[i] - prediction[2]) +
                _magnitude(planes.b[i] - prediction[3]);
          }
        }
        if (bestCost < 0 || cost < bestCost) {
          bestCost = cost;
          bestMode = mode;
        }
      }
      modes[by * blocksX + bx] = bestMode;
    }
  }
  return modes;
}

/// Each pixel minus its prediction, per channel, mod 256.
_Planes _predictorResiduals(
  _Planes planes,
  int width,
  int height,
  Uint8List modes,
  int blocksX,
) {
  final residuals = _Planes(width * height);
  final prediction = Int32List(4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      if (y == 0 && x == 0) {
        prediction
          ..[0] = 255
          ..[1] = 0
          ..[2] = 0
          ..[3] = 0;
      } else if (y == 0) {
        _copyPixel(planes, i - 1, prediction);
      } else if (x == 0) {
        _copyPixel(planes, i - width, prediction);
      } else {
        final block =
            (y >> _predictorBlockBits) * blocksX + (x >> _predictorBlockBits);
        _predict(modes[block], planes, i, width, prediction);
      }
      residuals.a[i] = (planes.a[i] - prediction[0]) & 0xff;
      residuals.r[i] = (planes.r[i] - prediction[1]) & 0xff;
      residuals.g[i] = (planes.g[i] - prediction[2]) & 0xff;
      residuals.b[i] = (planes.b[i] - prediction[3]) & 0xff;
    }
  }
  return residuals;
}

void _copyPixel(_Planes planes, int i, Int32List out) {
  out[0] = planes.a[i];
  out[1] = planes.r[i];
  out[2] = planes.g[i];
  out[3] = planes.b[i];
}

/// Writes pixel [i]'s (a, r, g, b) prediction under [mode] into [out]. Only
/// valid for a pixel that has left, top and top-left neighbors.
void _predict(int mode, _Planes planes, int i, int width, Int32List out) {
  final left = i - 1;
  final top = i - width;
  final topLeft = top - 1;
  if (mode == 11) {
    // Select: whichever of left/top is closer (Manhattan distance) to the
    // gradient estimate left + top - topLeft.
    final leftError =
        (planes.a[top] - planes.a[topLeft]).abs() +
        (planes.r[top] - planes.r[topLeft]).abs() +
        (planes.g[top] - planes.g[topLeft]).abs() +
        (planes.b[top] - planes.b[topLeft]).abs();
    final topError =
        (planes.a[left] - planes.a[topLeft]).abs() +
        (planes.r[left] - planes.r[topLeft]).abs() +
        (planes.g[left] - planes.g[topLeft]).abs() +
        (planes.b[left] - planes.b[topLeft]).abs();
    _copyPixel(planes, leftError < topError ? left : top, out);
    return;
  }
  out[0] = _predictChannel(mode, planes.a, left, top, topLeft);
  out[1] = _predictChannel(mode, planes.r, left, top, topLeft);
  out[2] = _predictChannel(mode, planes.g, left, top, topLeft);
  out[3] = _predictChannel(mode, planes.b, left, top, topLeft);
}

int _predictChannel(int mode, Uint8List c, int left, int top, int topLeft) {
  switch (mode) {
    case 1:
      return c[left];
    case 2:
      return c[top];
    case 7:
      return (c[left] + c[top]) >> 1;
    case 12: // ClampAddSubtractFull
      return _clamp255(c[left] + c[top] - c[topLeft]);
    case 13: // ClampAddSubtractHalf
      final average = (c[left] + c[top]) >> 1;
      return _clamp255(average + (average - c[topLeft]) ~/ 2);
  }
  throw StateError('Unsupported predictor mode $mode');
}

int _clamp255(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// A residual's magnitude, reading it as a signed byte.
int _magnitude(int difference) {
  final v = difference & 0xff;
  return v < 128 ? v : 256 - v;
}

/// Writes [planes] as a VP8L entropy-coded image: its prefix codes, then its
/// LZ77-tokenized pixels.
void _writeEntropyCodedImage(
  LsbBitWriter writer,
  _Planes planes,
  int width, {
  required bool isMainImage,
}) {
  writer.writeBits(0, 1); // no color cache
  if (isMainImage) writer.writeBits(0, 1); // no meta prefix codes

  final green = List<int>.filled(256 + 24, 0);
  final red = List<int>.filled(256, 0);
  final blue = List<int>.filled(256, 0);
  final alpha = List<int>.filled(256, 0);
  final distance = List<int>.filled(40, 0);
  _forEachToken(planes, width, (index, copyLength, planeCode) {
    if (copyLength == 0) {
      green[planes.g[index]]++;
      red[planes.r[index]]++;
      blue[planes.b[index]]++;
      alpha[planes.a[index]]++;
    } else {
      green[256 + _prefixSymbol(copyLength)]++;
      distance[_prefixSymbol(planeCode)]++;
    }
  });

  final greenCode = _PrefixCode.write(writer, green);
  final redCode = _PrefixCode.write(writer, red);
  final blueCode = _PrefixCode.write(writer, blue);
  final alphaCode = _PrefixCode.write(writer, alpha);
  final distanceCode = _PrefixCode.write(writer, distance);

  _forEachToken(planes, width, (index, copyLength, planeCode) {
    if (copyLength == 0) {
      greenCode.emit(writer, planes.g[index]);
      redCode.emit(writer, planes.r[index]);
      blueCode.emit(writer, planes.b[index]);
      alphaCode.emit(writer, planes.a[index]);
    } else {
      greenCode.emit(writer, 256 + _prefixSymbol(copyLength));
      _writePrefixExtraBits(writer, copyLength);
      distanceCode.emit(writer, _prefixSymbol(planeCode));
      _writePrefixExtraBits(writer, planeCode);
    }
  });
}

/// Walks [planes] in scan order as LZ77 tokens: a literal pixel
/// (`copyLength` 0), or `copyLength` pixels each repeating the pixel
/// [planeCode] refers to (the one to the left, or above).
void _forEachToken(
  _Planes planes,
  int width,
  void Function(int index, int copyLength, int planeCode) visit,
) {
  final count = planes.a.length;
  var i = 0;
  while (i < count) {
    final leftRun = i >= 1 ? _runLength(planes, i, 1) : 0;
    final aboveRun = i >= width ? _runLength(planes, i, width) : 0;
    final run = math.max(leftRun, aboveRun);
    if (run >= _minCopyLength) {
      visit(i, run, aboveRun > leftRun ? _planeCodeAbove : _planeCodeLeft);
      i += run;
    } else {
      visit(i, 0, 0);
      i++;
    }
  }
}

/// How many pixels from [start] on (at most [_maxCopyLength]) each equal the
/// pixel [distance] positions before them.
int _runLength(_Planes planes, int start, int distance) {
  final limit = math.min(planes.a.length, start + _maxCopyLength);
  var i = start;
  while (i < limit && planes.samePixel(i, i - distance)) {
    i++;
  }
  return i - start;
}

/// VP8L's prefix symbol for an LZ77 length or distance [value] (>= 1); the
/// remaining low bits follow as [_writePrefixExtraBits].
int _prefixSymbol(int value) {
  final n = value - 1;
  if (n < 4) return n;
  final highBit = n.bitLength - 1;
  return 2 * highBit + ((n >> (highBit - 1)) & 1);
}

void _writePrefixExtraBits(LsbBitWriter writer, int value) {
  final n = value - 1;
  if (n < 4) return;
  final extraBits = n.bitLength - 2;
  writer.writeBits(n & ((1 << extraBits) - 1), extraBits);
}

/// A prefix code as written to a VP8L bitstream, ready to emit symbols with.
class _PrefixCode {
  final Uint8List _lengths;
  final Int32List _codes;

  /// A code with a single symbol, which decoders read using zero bits.
  final bool _zeroBits;

  _PrefixCode._(this._lengths, this._zeroBits)
    : _codes = canonicalCodesLsb(_lengths);

  void emit(LsbBitWriter writer, int symbol) {
    if (!_zeroBits) writer.writeBits(_codes[symbol], _lengths[symbol]);
  }

  /// Builds a code from symbol [counts] and writes its definition.
  factory _PrefixCode.write(LsbBitWriter writer, List<int> counts) {
    final used = [
      for (var s = 0; s < counts.length; s++)
        if (counts[s] > 0) s,
    ];
    if (used.isEmpty) used.add(0);

    if (used.length <= 2 && used.last < 256) {
      writer
        ..writeBits(1, 1) // simple code
        ..writeBits(used.length - 1, 1);
      final first = used.first;
      if (first < 2) {
        writer
          ..writeBits(0, 1)
          ..writeBits(first, 1);
      } else {
        writer
          ..writeBits(1, 1)
          ..writeBits(first, 8);
      }
      if (used.length == 2) writer.writeBits(used.last, 8);
      final lengths = Uint8List(counts.length);
      for (final symbol in used) {
        lengths[symbol] = 1;
      }
      return _PrefixCode._(lengths, used.length == 1);
    }

    final lengths = huffmanCodeLengths(counts, 15);
    final codeLengthSymbols = runLengthEncodeCodeLengths(lengths);
    final codeLengthCounts = List<int>.filled(19, 0);
    for (final entry in codeLengthSymbols) {
      codeLengthCounts[entry & 0xff]++;
    }
    final codeLengthCode = _PrefixCode._(
      huffmanCodeLengths(codeLengthCounts, 7),
      codeLengthCounts.where((c) => c > 0).length == 1,
    );
    var listed = 19;
    while (listed > 4 &&
        codeLengthCode._lengths[_codeLengthOrder[listed - 1]] == 0) {
      listed--;
    }
    writer
      ..writeBits(0, 1) // normal code
      ..writeBits(listed - 4, 4);
    for (var i = 0; i < listed; i++) {
      writer.writeBits(codeLengthCode._lengths[_codeLengthOrder[i]], 3);
    }
    writer.writeBits(0, 1); // lengths cover the whole alphabet
    for (final entry in codeLengthSymbols) {
      final symbol = entry & 0xff;
      codeLengthCode.emit(writer, symbol);
      writer.writeBits(entry >> 8, codeLengthExtraBits(symbol));
    }
    return _PrefixCode._(lengths, used.length == 1);
  }
}
