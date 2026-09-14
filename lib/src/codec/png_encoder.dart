import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_output.dart';
import 'rgba_image.dart';
import 'zlib.dart';

const _signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const _ihdr = [0x49, 0x48, 0x44, 0x52];
const _idat = [0x49, 0x44, 0x41, 0x54];
const _iend = [0x49, 0x45, 0x4e, 0x44];
const _maxIdatLength = 1 << 20;

/// Encodes [image] as a non-interlaced, 8-bit RGBA PNG.
///
/// Each row is filtered with whichever of PNG's five filters leaves the
/// smallest sum of absolute residuals (libpng's heuristic) before zlib
/// compression.
Uint8List encodePng(RgbaImage image) {
  final width = image.width;
  final height = image.height;
  if (width < 1 || height < 1) {
    throw ArgumentError('PNG needs at least a 1x1 image, got ${width}x$height');
  }
  final stride = width * 4;
  final pixels = image.pixels;
  final filtered = Uint8List((stride + 1) * height);
  final filters = _RowFilters(stride);
  final zeroRow = Uint8List(stride);
  for (var y = 0; y < height; y++) {
    final rowStart = y * stride;
    final filter = filters.filterRow(
      pixels,
      rowStart,
      y == 0 ? zeroRow : pixels,
      y == 0 ? 0 : rowStart - stride,
    );
    final offset = y * (stride + 1);
    filtered[offset] = filter;
    if (filter == 0) {
      filtered.setRange(offset + 1, offset + 1 + stride, pixels, rowStart);
    } else {
      filtered.setRange(offset + 1, offset + 1 + stride, filters.rows[filter]);
    }
  }
  final compressed = zlibEncode(filtered);

  final out = ByteOutput(compressed.length + 64);
  out.addBytes(_signature);
  final header = Uint8List(13);
  ByteData.sublistView(header)
    ..setUint32(0, width)
    ..setUint32(4, height);
  header[8] = 8; // bit depth
  header[9] = 6; // color type: truecolor with alpha
  _writeChunk(out, _ihdr, header);
  for (var start = 0; start < compressed.length; start += _maxIdatLength) {
    final end = math.min(start + _maxIdatLength, compressed.length);
    _writeChunk(out, _idat, Uint8List.sublistView(compressed, start, end));
  }
  _writeChunk(out, _iend, Uint8List(0));
  return out.toBytes();
}

/// Scratch rows holding the current row filtered with each PNG filter type.
class _RowFilters {
  final int stride;

  /// Indexed by filter type. Entry 0 (None) is never written: that filter's
  /// output is the row itself.
  final List<Uint8List> rows;

  _RowFilters(this.stride)
    : rows = List.generate(5, (_) => Uint8List(stride));

  /// Filters `row[rowStart..]` against `above[aboveStart..]` with every
  /// filter type in one pass and returns the type whose residuals, read as
  /// signed bytes, have the smallest absolute sum.
  int filterRow(Uint8List row, int rowStart, Uint8List above, int aboveStart) {
    final sub = rows[1], up = rows[2], average = rows[3], paeth = rows[4];
    // Local copy: skips the top-level variable's lazy-initialization check
    // on every access in this hot loop.
    final magnitudes = _magnitudes;
    var noneSum = 0, subSum = 0, upSum = 0, averageSum = 0, paethSum = 0;
    for (var i = 0; i < stride; i++) {
      final x = row[rowStart + i];
      final top = above[aboveStart + i];
      final left = i < 4 ? 0 : row[rowStart + i - 4];
      final topLeft = i < 4 ? 0 : above[aboveStart + i - 4];
      noneSum += magnitudes[x];

      var residual = (x - left) & 0xff;
      sub[i] = residual;
      subSum += magnitudes[residual];

      residual = (x - top) & 0xff;
      up[i] = residual;
      upSum += magnitudes[residual];

      residual = (x - ((left + top) >> 1)) & 0xff;
      average[i] = residual;
      averageSum += magnitudes[residual];

      // Paeth: whichever neighbor is closest to left + top - topLeft.
      final toLeft = (top - topLeft).abs();
      final toTop = (left - topLeft).abs();
      final toTopLeft = (left + top - 2 * topLeft).abs();
      final predicted = toLeft <= toTop && toLeft <= toTopLeft
          ? left
          : (toTop <= toTopLeft ? top : topLeft);
      residual = (x - predicted) & 0xff;
      paeth[i] = residual;
      paethSum += magnitudes[residual];
    }
    var best = 0;
    var bestSum = noneSum;
    if (subSum < bestSum) {
      best = 1;
      bestSum = subSum;
    }
    if (upSum < bestSum) {
      best = 2;
      bestSum = upSum;
    }
    if (averageSum < bestSum) {
      best = 3;
      bestSum = averageSum;
    }
    if (paethSum < bestSum) best = 4;
    return best;
  }
}

/// Each residual byte's magnitude, reading it as signed.
final _magnitudes = Uint8List.fromList([
  for (var v = 0; v < 256; v++) v < 128 ? v : 256 - v,
]);

void _writeChunk(ByteOutput out, List<int> type, Uint8List data) {
  out
    ..addUint32Be(data.length)
    ..addBytes(type)
    ..addBytes(data)
    ..addUint32Be(_crc32(_crc32(0xffffffff, type), data) ^ 0xffffffff);
}

int _crc32(int crc, List<int> bytes) {
  final table = _crcTable;
  for (final byte in bytes) {
    crc = table[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return crc;
}

final _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();
