// The MQ arithmetic coder of ISO/IEC 15444-1 Annex C, plus the raw
// (bypass) bit coding that selective arithmetic coding bypass uses.
import 'dart:typed_data';

/// Probability estimation table (Table C.2): per state, Qe and the next
/// state after coding an MPS or an LPS, and whether an LPS swaps the MPS.
const _qe = [
  0x5601, 0x3401, 0x1801, 0x0AC1, 0x0521, 0x0221, 0x5601, 0x5401, //
  0x4801, 0x3801, 0x3001, 0x2401, 0x1C01, 0x1601, 0x5601, 0x5401,
  0x5101, 0x4801, 0x3801, 0x3401, 0x3001, 0x2801, 0x2401, 0x2201,
  0x1C01, 0x1801, 0x1601, 0x1401, 0x1201, 0x1101, 0x0AC1, 0x09C1,
  0x08A1, 0x0521, 0x0441, 0x02A1, 0x0221, 0x0141, 0x0111, 0x0085,
  0x0049, 0x0025, 0x0015, 0x0009, 0x0005, 0x0001, 0x5601,
];
const _nmps = [
  1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, //
  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
  33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 45, 46,
];
const _nlps = [
  1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, //
  15, 16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
  30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46,
];
const _switch = [
  1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// Per packed context state (`index << 1 | mps`): Qe in the low 16 bits,
/// the packed state after an MPS in bits 16-22 and after an LPS (MPS
/// swapped where Table C.2 says so) in bits 23-29 — one lookup per symbol.
final Int32List _states = () {
  final table = Int32List(2 * _qe.length);
  for (var index = 0; index < _qe.length; index++) {
    for (var mps = 0; mps < 2; mps++) {
      final afterMps = (_nmps[index] << 1) | mps;
      final afterLps =
          (_nlps[index] << 1) | (_switch[index] == 1 ? 1 - mps : mps);
      table[(index << 1) | mps] =
          _qe[index] | (afterMps << 16) | (afterLps << 23);
    }
  }
  return table;
}();

/// Number of coding contexts tier-1 uses: 9 significance, 5 sign, 3
/// magnitude refinement, run-length and uniform.
const mqContextCount = 19;
const ctxRunLength = 17;
const ctxUniform = 18;

/// A context's state packed as `index << 1 | mps`.
typedef MqContexts = Uint8List;

MqContexts newMqContexts() => resetMqContexts(Uint8List(mqContextCount));

/// Resets every context to its initial state (D.7): all at state 0 with
/// MPS 0, except uniform (46), run-length (3) and the all-zero-neighbour
/// significance context (4).
MqContexts resetMqContexts(MqContexts contexts) {
  contexts.fillRange(0, mqContextCount, 0);
  contexts[ctxUniform] = 46 << 1;
  contexts[ctxRunLength] = 3 << 1;
  contexts[0] = 4 << 1;
  return contexts;
}

/// Two 0xFF bytes: what reading past a segment's end yields (see
/// [MqDecoder.start]).
const segmentPadding = 2;

/// [data] if two 0xFF bytes follow [end] in it, else a copy of
/// `data[start, end)` that has them, and where the segment starts in it.
(Uint8List, int) _padded(Uint8List data, int start, int end) {
  if (end + segmentPadding <= data.length &&
      data[end] == 0xFF &&
      data[end + 1] == 0xFF) {
    return (data, start);
  }
  final copy = Uint8List(end - start + segmentPadding)
    ..setRange(0, end - start, data, start);
  copy[end - start] = 0xFF;
  copy[end - start + 1] = 0xFF;
  return (copy, 0);
}

/// Decodes MQ codeword segments (C.3), one [start]ed at a time.
///
/// The standard has a decoder read past a segment's end as 0xFF bytes. Two
/// real 0xFF bytes after the segment do the same — a 0xFF followed by a
/// byte above 0x8F reads as a marker, which the decoder never moves past —
/// so the byte loop needs no bounds checks. C is one 32-bit register,
/// masked after every shift, which keeps it exact on the web too.
class MqDecoder {
  // An instance field reads faster than the lazily initialized global.
  final Int32List _table = _states;
  Uint8List _data = Uint8List(0);
  int _bp = 0;
  int _a = 0;
  int _c = 0;
  int _ct = 0;

  /// Starts decoding `data[start, end)`. Tier-1 passes code-block data
  /// with [segmentPadding] 0xFF bytes after each segment already; any
  /// other segment is copied into a buffer that has them.
  void start(Uint8List data, int start, int end) {
    final (padded, from) = _padded(data, start, end);
    _data = padded;
    _bp = from;
    // INITDEC (C.3.5).
    _c = padded[from] << 16;
    _byteIn();
    _c = (_c << 7) & 0xFFFFFFFF;
    _ct -= 7;
    _a = 0x8000;
  }

  @pragma('vm:never-inline')
  @pragma('dart2js:never-inline')
  void _byteIn() {
    final data = _data;
    final bp = _bp;
    if (data[bp] == 0xFF) {
      final next = data[bp + 1];
      if (next > 0x8F) {
        _c += 0xFF00;
        _ct = 8;
      } else {
        _bp = bp + 1;
        _c += next << 9;
        _ct = 7;
      }
    } else {
      _bp = bp + 1;
      _c += data[bp + 1] << 8;
      _ct = 8;
    }
  }

  /// Decodes one symbol in context [cx] (C.3.2), updating its state.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int decode(MqContexts contexts, int cx) {
    final state = contexts[cx];
    final entry = _table[state];
    final qe = entry & 0xFFFF;
    var a = _a - qe;
    int d;
    if (_c < (qe << 16)) {
      // LPS exchange.
      if (a < qe) {
        d = state & 1;
        contexts[cx] = (entry >> 16) & 0x7F;
      } else {
        d = (state & 1) ^ 1;
        contexts[cx] = (entry >> 23) & 0x7F;
      }
      a = qe;
    } else {
      _c -= qe << 16;
      if ((a & 0x8000) != 0) {
        _a = a;
        return state & 1;
      }
      // MPS exchange.
      if (a < qe) {
        d = (state & 1) ^ 1;
        contexts[cx] = (entry >> 23) & 0x7F;
      } else {
        d = state & 1;
        contexts[cx] = (entry >> 16) & 0x7F;
      }
    }
    // Renormalize (C.3.3) over registers; the byte in is rare.
    var c = _c;
    var ct = _ct;
    do {
      if (ct == 0) {
        _c = c;
        _byteIn();
        c = _c;
        ct = _ct;
      }
      a <<= 1;
      c = (c << 1) & 0xFFFFFFFF;
      ct--;
    } while ((a & 0x8000) == 0);
    _a = a;
    _c = c;
    _ct = ct;
    return d;
  }
}

/// Reads raw (bypass-coded) segments one bit at a time: bits MSB first,
/// with a 0 bit stuffed after every 0xFF byte (D.6). Past the end it reads
/// 1 bits, like [MqDecoder] does 0xFF bytes.
class RawBitDecoder {
  Uint8List _data = Uint8List(0);
  int _bp = 0;
  int _c = 0;
  int _ct = 0;

  void start(Uint8List data, int start, int end) {
    final (padded, from) = _padded(data, start, end);
    _data = padded;
    _bp = from;
    _c = 0;
    _ct = 0;
  }

  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int decode() {
    if (_ct == 0) {
      final next = _data[_bp];
      if (_c == 0xFF) {
        if (next > 0x8F) {
          _ct = 8;
        } else {
          _c = next;
          _bp++;
          _ct = 7;
        }
      } else {
        _c = next;
        _bp++;
        _ct = 8;
      }
    }
    _ct--;
    return (_c >> _ct) & 1;
  }
}

/// Encodes one MQ codeword (C.2). [bytes] counts the bytes produced so
/// far, which rate allocation uses to estimate each coding pass's length.
class MqEncoder {
  final Int32List _table = _states;

  /// Output, with index 0 a scratch byte that stands for the one before the
  /// codeword (the standard's `BP = BPST - 1`), so it's never emitted.
  Uint8List _out = Uint8List(1024);
  int _bp = 0;
  int _a = 0x8000;
  int _c = 0;
  int _ct = 12;

  /// Bytes of codeword written so far.
  int get bytes => _bp;

  /// Encodes symbol [d] in context [cx] (C.2.2), updating its state.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  void encode(MqContexts contexts, int cx, int d) {
    final state = contexts[cx];
    final entry = _table[state];
    final qe = entry & 0xFFFF;
    var a = _a - qe;
    var c = _c;
    if (d == (state & 1)) {
      if ((a & 0x8000) != 0) {
        _a = a;
        _c = c + qe;
        return;
      }
      if (a < qe) {
        a = qe;
      } else {
        c += qe;
      }
      contexts[cx] = (entry >> 16) & 0x7F;
    } else {
      if (a < qe) {
        c += qe;
      } else {
        a = qe;
      }
      contexts[cx] = (entry >> 23) & 0x7F;
    }
    // Renormalize (C.2.5) over registers; the byte out is rare.
    var ct = _ct;
    do {
      a <<= 1;
      c <<= 1;
      ct--;
      if (ct == 0) {
        _c = c;
        _byteOut();
        c = _c;
        ct = _ct;
      }
    } while ((a & 0x8000) == 0);
    _a = a;
    _c = c;
    _ct = ct;
  }

  void _put(int byte) {
    _bp++;
    if (_bp == _out.length) {
      _out = Uint8List(_out.length * 2)..setRange(0, _out.length, _out);
    }
    _out[_bp] = byte;
  }

  void _byteOut() {
    if (_out[_bp] == 0xFF) {
      _put(_c >> 20);
      _c &= 0xFFFFF;
      _ct = 7;
    } else if ((_c & 0x8000000) == 0) {
      _put(_c >> 19);
      _c &= 0x7FFFF;
      _ct = 8;
    } else {
      _out[_bp]++;
      if (_out[_bp] == 0xFF) {
        _c &= 0x7FFFFFF;
        _put(_c >> 20);
        _c &= 0xFFFFF;
        _ct = 7;
      } else {
        _put(_c >> 19);
        _c &= 0x7FFFF;
        _ct = 8;
      }
    }
  }

  /// Terminates the codeword (C.2.9) and returns it. A trailing 0xFF is
  /// dropped: the decoder reads past the end as 0xFF anyway.
  Uint8List finish() {
    final tempC = _c + _a;
    _c |= 0xFFFF;
    if (_c >= tempC) _c -= 0x8000;
    _c <<= _ct;
    _byteOut();
    _c <<= _ct;
    _byteOut();
    var end = _bp;
    if (_out[end] == 0xFF) end--;
    return Uint8List.sublistView(_out, 1, end + 1);
  }
}
