import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_output.dart';
import 'rgba_image.dart';

/// A baseline (sequential, Huffman-coded) JFIF JPEG encoder.
///
/// Writes YCbCr with no chroma subsampling (4:4:4), using the ITU T.81
/// Annex K example quantization tables scaled by [quality] with libjpeg's
/// formula, and the Annex K Huffman tables. Alpha is ignored. The scaled
/// tables are computed once, so reuse an encoder across images of the same
/// quality.
class JpegEncoder {
  /// 1 (smallest file) to 100 (best quality). Values outside that range are
  /// clamped, as libjpeg does.
  final int quality;

  final _lumaQuant = Uint8List(64);
  final _chromaQuant = Uint8List(64);

  /// Reciprocal quantization steps in zigzag order, with the AAN DCT's
  /// per-coefficient output scaling (and its overall factor of 8) folded in.
  final _lumaDivisors = Float64List(64);
  final _chromaDivisors = Float64List(64);

  JpegEncoder({required int quality})
    : quality = math.max(1, math.min(100, quality)) {
    final scale = this.quality < 50
        ? 5000 ~/ this.quality
        : 200 - this.quality * 2;
    for (var i = 0; i < 64; i++) {
      _lumaQuant[i] = _scaleQuant(_baseLumaQuant[i], scale);
      _chromaQuant[i] = _scaleQuant(_baseChromaQuant[i], scale);
    }
    for (var k = 0; k < 64; k++) {
      final i = _zigzagOrder[k];
      final aan = _aanScale[i >> 3] * _aanScale[i & 7] * 8;
      _lumaDivisors[k] = 1 / (_lumaQuant[i] * aan);
      _chromaDivisors[k] = 1 / (_chromaQuant[i] * aan);
    }
  }

  Uint8List encode(RgbaImage image) {
    final width = image.width;
    final height = image.height;
    if (width < 1 || height < 1 || width > 65535 || height > 65535) {
      throw ArgumentError(
        'JPEG dimensions must be 1-65535 px per side, got ${width}x$height',
      );
    }
    final out = ByteOutput(math.max(1024, width * height ~/ 4));
    _writeHeaders(out, width, height);

    final bits = _JpegBitWriter(out);
    final yBlock = Float64List(64);
    final cbBlock = Float64List(64);
    final crBlock = Float64List(64);
    final quantized = Int32List(64);
    // Byte offsets of the current block's source rows and columns. Blocks
    // overhanging the right/bottom edge repeat the edge pixels, which
    // compresses better than padding with a flat color.
    final rowOffsets = List<int>.filled(8, 0);
    final columnOffsets = List<int>.filled(8, 0);
    final pixels = image.pixels;
    var yDc = 0, cbDc = 0, crDc = 0;
    for (var blockY = 0; blockY < height; blockY += 8) {
      for (var i = 0; i < 8; i++) {
        rowOffsets[i] = math.min(blockY + i, height - 1) * width * 4;
      }
      for (var blockX = 0; blockX < width; blockX += 8) {
        for (var i = 0; i < 8; i++) {
          columnOffsets[i] = math.min(blockX + i, width - 1) * 4;
        }
        var k = 0;
        for (var row = 0; row < 8; row++) {
          final rowOffset = rowOffsets[row];
          for (var col = 0; col < 8; col++) {
            final p = rowOffset + columnOffsets[col];
            final r = pixels[p];
            final g = pixels[p + 1];
            final b = pixels[p + 2];
            yBlock[k] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
            cbBlock[k] = -0.168736 * r - 0.331264 * g + 0.5 * b;
            crBlock[k] = 0.5 * r - 0.418688 * g - 0.081312 * b;
            k++;
          }
        }
        yDc = _encodeBlock(
          bits,
          yBlock,
          _lumaDivisors,
          yDc,
          _lumaDcTable,
          _lumaAcTable,
          quantized,
        );
        cbDc = _encodeBlock(
          bits,
          cbBlock,
          _chromaDivisors,
          cbDc,
          _chromaDcTable,
          _chromaAcTable,
          quantized,
        );
        crDc = _encodeBlock(
          bits,
          crBlock,
          _chromaDivisors,
          crDc,
          _chromaDcTable,
          _chromaAcTable,
          quantized,
        );
      }
    }
    bits.flush();
    out
      ..addByte(0xff)
      ..addByte(0xd9); // EOI
    return out.toBytes();
  }

  void _writeHeaders(ByteOutput out, int width, int height) {
    out.addBytes(const [
      0xff, 0xd8, // SOI
      // APP0: JFIF 1.01, no density units (1:1 aspect), no thumbnail.
      0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
      0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
      // DQT: two 8-bit tables, 2 + 2 * 65 bytes.
      0xff, 0xdb, 0x00, 0x84,
    ]);
    out.addByte(0);
    for (var k = 0; k < 64; k++) {
      out.addByte(_lumaQuant[_zigzagOrder[k]]);
    }
    out.addByte(1);
    for (var k = 0; k < 64; k++) {
      out.addByte(_chromaQuant[_zigzagOrder[k]]);
    }

    out.addBytes([
      0xff, 0xc0, 0x00, 0x11, 0x08, // SOF0, 8-bit samples
      height >> 8, height & 0xff, width >> 8, width & 0xff,
      0x03, // components: id, sampling factors (1x1), quant table
      0x01, 0x11, 0x00,
      0x02, 0x11, 0x01,
      0x03, 0x11, 0x01,
    ]);

    var length = 2;
    for (final (_, table) in _huffmanTables) {
      length += 1 + 16 + table.symbols.length;
    }
    out.addBytes([0xff, 0xc4, length >> 8, length & 0xff]); // DHT
    for (final (id, table) in _huffmanTables) {
      out
        ..addByte(id)
        ..addBytes(table.counts)
        ..addBytes(table.symbols);
    }

    out.addBytes(const [
      0xff, 0xda, 0x00, 0x0c, 0x03, // SOS, 3 components
      0x01, 0x00, 0x02, 0x11, 0x03, 0x11, // id, DC/AC table ids
      0x00, 0x3f, 0x00, // spectral selection 0-63, no approximation
    ]);
  }

  /// DCT-transforms, quantizes and entropy-codes one 8x8 [block], returning
  /// its quantized DC coefficient (the next block's DC predictor).
  static int _encodeBlock(
    _JpegBitWriter bits,
    Float64List block,
    Float64List divisors,
    int previousDc,
    _JpegHuffmanTable dcTable,
    _JpegHuffmanTable acTable,
    Int32List quantized,
  ) {
    _forwardDct(block);
    // A local copy skips the top-level variable's lazy-initialization check
    // on every access in this hot loop.
    final zigzagOrder = _zigzagOrder;
    for (var k = 0; k < 64; k++) {
      // Round to nearest: the offset keeps the value positive, so truncating
      // acts as floor (libjpeg's own trick).
      final q =
          (block[zigzagOrder[k]] * divisors[k] + 16384.5).toInt() - 16384;
      // 8-bit samples keep every coefficient within these bounds; the clamp
      // only guards against floating-point rounding at the extremes.
      quantized[k] = q < -1023 ? -1023 : (q > 1023 ? 1023 : q);
    }

    final dc = quantized[0];
    final dcDiff = dc - previousDc;
    final dcCategory = dcDiff.abs().bitLength;
    bits.write(dcTable.codes[dcCategory], dcTable.lengths[dcCategory]);
    bits.write(_magnitudeBits(dcDiff, dcCategory), dcCategory);

    final acCodes = acTable.codes;
    final acLengths = acTable.lengths;
    var zeroRun = 0;
    for (var k = 1; k < 64; k++) {
      final value = quantized[k];
      if (value == 0) {
        zeroRun++;
        continue;
      }
      while (zeroRun >= 16) {
        bits.write(acCodes[0xf0], acLengths[0xf0]); // ZRL
        zeroRun -= 16;
      }
      final category = value.abs().bitLength;
      final symbol = (zeroRun << 4) | category;
      bits.write(acCodes[symbol], acLengths[symbol]);
      bits.write(_magnitudeBits(value, category), category);
      zeroRun = 0;
    }
    if (zeroRun > 0) bits.write(acCodes[0x00], acLengths[0x00]); // EOB
    return dc;
  }

  /// T.81's representation of [value] in [category] bits: negative values
  /// are stored as their one's complement.
  static int _magnitudeBits(int value, int category) =>
      value < 0 ? value + (1 << category) - 1 : value;

  /// In-place float AAN forward DCT (libjpeg's `jfdctflt.c`): rows, then
  /// columns.
  static void _forwardDct(Float64List d) {
    for (var row = 0; row < 8; row++) {
      _dct1d(d, row * 8, 1);
    }
    for (var col = 0; col < 8; col++) {
      _dct1d(d, col, 8);
    }
  }

  static void _dct1d(Float64List d, int o, int step) {
    final i0 = o, i1 = o + step, i2 = o + 2 * step, i3 = o + 3 * step;
    final i4 = o + 4 * step, i5 = o + 5 * step, i6 = o + 6 * step;
    final i7 = o + 7 * step;
    final tmp0 = d[i0] + d[i7], tmp7 = d[i0] - d[i7];
    final tmp1 = d[i1] + d[i6], tmp6 = d[i1] - d[i6];
    final tmp2 = d[i2] + d[i5], tmp5 = d[i2] - d[i5];
    final tmp3 = d[i3] + d[i4], tmp4 = d[i3] - d[i4];

    // Even part.
    final tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3;
    final tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
    d[i0] = tmp10 + tmp11;
    d[i4] = tmp10 - tmp11;
    final z1 = (tmp12 + tmp13) * 0.707106781;
    d[i2] = tmp13 + z1;
    d[i6] = tmp13 - z1;

    // Odd part.
    final odd10 = tmp4 + tmp5, odd11 = tmp5 + tmp6, odd12 = tmp6 + tmp7;
    final z5 = (odd10 - odd12) * 0.382683433;
    final z2 = 0.541196100 * odd10 + z5;
    final z4 = 1.306562965 * odd12 + z5;
    final z3 = odd11 * 0.707106781;
    final z11 = tmp7 + z3, z13 = tmp7 - z3;
    d[i5] = z13 + z2;
    d[i3] = z13 - z2;
    d[i1] = z11 + z4;
    d[i7] = z11 - z4;
  }
}

int _scaleQuant(int base, int scale) =>
    math.max(1, math.min(255, (base * scale + 50) ~/ 100));

/// Accumulates JPEG entropy-coded data most-significant bit first, stuffing
/// a zero byte after every 0xFF.
class _JpegBitWriter {
  final ByteOutput _out;
  int _buffer = 0;
  int _count = 0;

  _JpegBitWriter(this._out);

  /// Appends the low [length] (at most 16) bits of [value].
  void write(int value, int length) {
    _buffer = (_buffer << length) | (value & ((1 << length) - 1));
    _count += length;
    while (_count >= 8) {
      _count -= 8;
      final byte = (_buffer >> _count) & 0xff;
      _out.addByte(byte);
      if (byte == 0xff) _out.addByte(0);
    }
    _buffer &= (1 << _count) - 1;
  }

  /// Pads the final partial byte with 1 bits, as T.81 requires.
  void flush() {
    if (_count > 0) write((1 << (8 - _count)) - 1, 8 - _count);
  }
}

/// One Huffman table in DHT form ([counts] of codes per length 1-16, then
/// [symbols] in code order), plus each symbol's code and code length.
class _JpegHuffmanTable {
  final List<int> counts;
  final List<int> symbols;
  final codes = Int32List(256);
  final lengths = Uint8List(256);

  _JpegHuffmanTable(this.counts, this.symbols) {
    var code = 0;
    var k = 0;
    for (var length = 1; length <= 16; length++) {
      for (var i = 0; i < counts[length - 1]; i++) {
        codes[symbols[k]] = code++;
        lengths[symbols[k]] = length;
        k++;
      }
      code <<= 1;
    }
  }
}

/// Natural (row-major) index of each coefficient in zigzag order.
final _zigzagOrder = Uint8List.fromList(const [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, //
  12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
]);

const _aanScale = [
  1.0, 1.387039845, 1.306562965, 1.175875602, //
  1.0, 0.785694958, 0.541196100, 0.275899379,
];

/// T.81 Table K.1, in natural order.
const _baseLumaQuant = [
  16, 11, 10, 16, 24, 40, 51, 61, //
  12, 12, 14, 19, 26, 58, 60, 55,
  14, 13, 16, 24, 40, 57, 69, 56,
  14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77,
  24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101,
  72, 92, 95, 98, 112, 100, 103, 99,
];

/// T.81 Table K.2, in natural order.
const _baseChromaQuant = [
  17, 18, 24, 47, 99, 99, 99, 99, //
  18, 21, 26, 66, 99, 99, 99, 99,
  24, 26, 56, 99, 99, 99, 99, 99,
  47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
];

/// T.81 Tables K.3-K.6.
final _lumaDcTable = _JpegHuffmanTable(
  const [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
  const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
);

final _chromaDcTable = _JpegHuffmanTable(
  const [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
  const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
);

final _lumaAcTable = _JpegHuffmanTable(
  const [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d],
  const [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, //
    0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
    0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45,
    0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
    0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9,
    0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4,
    0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
  ],
);

final _chromaAcTable = _JpegHuffmanTable(
  const [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77],
  const [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, //
    0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1,
    0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44,
    0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74,
    0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
    0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7,
    0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4,
    0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
  ],
);

/// The DHT segment's tables, keyed by their class/id byte.
final _huffmanTables = [
  (0x00, _lumaDcTable),
  (0x10, _lumaAcTable),
  (0x01, _chromaDcTable),
  (0x11, _chromaAcTable),
];
