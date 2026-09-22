// Tier-2 of ISO/IEC 15444-1 (Annex B.10): the bit-level I/O packet headers
// use, and the tag trees they code inclusion and zero bit-planes with.
import 'dart:typed_data';

/// Reads packet-header bits MSB first. A byte following 0xFF only carries 7
/// bits (its MSB is a stuffed 0), which keeps headers free of markers.
class HeaderBitReader {
  final Uint8List _data;
  final int _end;
  int _pos;
  int _buf = 0;
  int _ct = 0;

  HeaderBitReader(this._data, this._pos, this._end);

  /// Offset of the next unread byte.
  int get position => _pos;

  int bit() {
    if (_ct == 0) {
      _buf = (_buf << 8) & 0xFFFF;
      _ct = _buf == 0xFF00 ? 7 : 8;
      if (_pos >= _end) throw const _EndOfHeader();
      _buf |= _data[_pos++];
    }
    _ct--;
    return (_buf >> _ct) & 1;
  }

  int bits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | bit();
    }
    return v;
  }

  /// Skips to the next byte boundary — past one more byte if the last one
  /// read was 0xFF, since that byte's successor is part of the header.
  void align() {
    if ((_buf & 0xFF) == 0xFF && _pos < _end) _pos++;
    _ct = 0;
    _buf = 0;
  }

  /// Skips an EPH marker if one comes next (at a byte boundary).
  void skipEph() {
    if (_pos + 1 < _end && _data[_pos] == 0xFF && _data[_pos + 1] == 0x92) {
      _pos += 2;
    }
  }
}

/// Thrown when a packet header runs past the data holding it.
class _EndOfHeader implements Exception {
  const _EndOfHeader();
}

/// Whether [e] is a packet header running out of data (truncated stream).
bool isEndOfHeader(Object e) => e is _EndOfHeader;

/// Writes packet-header bits, with the same bit stuffing [HeaderBitReader]
/// expects.
class HeaderBitWriter {
  final BytesBuilder _out = BytesBuilder();
  int _buf = 0;
  int _ct = 8;
  int _last = 0;

  void bit(int b) {
    if (_ct == 0) _flushByte();
    _ct--;
    _buf |= (b & 1) << _ct;
  }

  void bits(int value, int n) {
    for (var i = n - 1; i >= 0; i--) {
      bit((value >> i) & 1);
    }
  }

  void _flushByte() {
    _out.addByte(_buf);
    _last = _buf;
    _buf = 0;
    _ct = _last == 0xFF ? 7 : 8;
  }

  /// Pads the last byte with zeros, plus a whole byte after a trailing
  /// 0xFF, and returns everything written.
  Uint8List finish() {
    if (_ct < (_last == 0xFF ? 7 : 8)) _flushByte();
    if (_last == 0xFF) {
      _out.addByte(0);
      _last = 0;
    }
    return _out.takeBytes();
  }
}

/// A tag tree (B.10.2): a quad-tree over a precinct's code-blocks whose
/// nodes hold the minimum of their children, coding each leaf's value
/// incrementally against a rising threshold.
class TagTree {
  final int width;
  final int height;

  /// Level sizes, leaves first; nodes are numbered level by level.
  final List<(int, int)> _levels;
  final List<int> _levelStart;
  final Int32List _value;
  final Int32List _low;
  final Uint8List _known;

  static const unknown = 0x7FFFFFFF;

  factory TagTree(int width, int height) {
    final levels = <(int, int)>[];
    final starts = <int>[];
    var w = width, h = height, total = 0;
    while (true) {
      levels.add((w, h));
      starts.add(total);
      total += w * h;
      if (w <= 1 && h <= 1) break;
      w = (w + 1) >> 1;
      h = (h + 1) >> 1;
    }
    return TagTree._(width, height, levels, starts, total);
  }

  TagTree._(this.width, this.height, this._levels, this._levelStart, int total)
    : _value = Int32List(total)..fillRange(0, total, unknown),
      _low = Int32List(total),
      _known = Uint8List(total);

  /// Node indices from [leaf] up to the root.
  List<int> _path(int leaf) {
    final path = <int>[];
    var x = leaf % width, y = leaf ~/ width;
    for (var l = 0; l < _levels.length; l++) {
      path.add(_levelStart[l] + y * _levels[l].$1 + x);
      x >>= 1;
      y >>= 1;
    }
    return path;
  }

  /// Reads bits until [leaf]'s value is known to be below [threshold] or
  /// not; returns whether it is.
  bool decode(HeaderBitReader reader, int leaf, int threshold) {
    final path = _path(leaf);
    var low = 0;
    for (var k = path.length - 1; k >= 0; k--) {
      final node = path[k];
      if (low > _low[node]) {
        _low[node] = low;
      } else {
        low = _low[node];
      }
      while (low < threshold && low < _value[node]) {
        if (reader.bit() == 1) {
          _value[node] = low;
        } else {
          low++;
        }
      }
      _low[node] = low;
    }
    return _value[path[0]] < threshold;
  }

  /// Sets every leaf's value (row-major) and each node's to its children's
  /// minimum, ready for [encode].
  void setValues(List<int> leaves) {
    for (var i = 0; i < leaves.length; i++) {
      _value[i] = leaves[i];
    }
    for (var l = 1; l < _levels.length; l++) {
      final (w, h) = _levels[l];
      final (cw, ch) = _levels[l - 1];
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          var m = unknown;
          for (var dy = 0; dy < 2; dy++) {
            for (var dx = 0; dx < 2; dx++) {
              final cx = 2 * x + dx, cy = 2 * y + dy;
              if (cx < cw && cy < ch) {
                final v = _value[_levelStart[l - 1] + cy * cw + cx];
                if (v < m) m = v;
              }
            }
          }
          _value[_levelStart[l] + y * w + x] = m;
        }
      }
    }
  }

  /// Writes what a decoder needs to tell whether [leaf]'s value is below
  /// [threshold].
  void encode(HeaderBitWriter writer, int leaf, int threshold) {
    final path = _path(leaf);
    var low = 0;
    for (var k = path.length - 1; k >= 0; k--) {
      final node = path[k];
      if (low > _low[node]) {
        _low[node] = low;
      } else {
        low = _low[node];
      }
      while (low < threshold) {
        if (low >= _value[node]) {
          if (_known[node] == 0) {
            writer.bit(1);
            _known[node] = 1;
          }
          break;
        }
        writer.bit(0);
        low++;
      }
      _low[node] = low;
    }
  }
}

/// Reads a number of coding passes (Table B.4).
int readPassCount(HeaderBitReader r) {
  if (r.bit() == 0) return 1;
  if (r.bit() == 0) return 2;
  final two = r.bits(2);
  if (two != 3) return 3 + two;
  final five = r.bits(5);
  if (five != 31) return 6 + five;
  return 37 + r.bits(7);
}

void writePassCount(HeaderBitWriter w, int n) {
  if (n == 1) {
    w.bit(0);
  } else if (n == 2) {
    w.bits(2, 2);
  } else if (n <= 5) {
    w.bits(0xC | (n - 3), 4);
  } else if (n <= 36) {
    w.bits(0x1E0 | (n - 6), 9);
  } else {
    w.bits(0xFF80 | (n - 37), 16);
  }
}

int floorLog2(int n) => n.bitLength - 1;
