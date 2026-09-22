// Tier-1 of ISO/IEC 15444-1 (Annex D): the bit-plane coding of one
// code-block's quantized coefficients into MQ-coded passes, and back.
//
// Passes scan a code-block four rows (a stripe) at a time, column by
// column, so the state they keep is one word per stripe column, laid out
// as OpenJPEG lays it out: the significance of the 3 x 6 neighbourhood the
// column's four coefficients see, and per row its sign, whether it was
// refined and whether this bit-plane's significance pass visited it. A
// row's contexts are then a shift and a table lookup, and a column with
// nothing to code is skipped on a single test.
import 'dart:typed_data';

import 'mq_coder.dart';

/// Code-block style flags (SPcod/SPcoc, Table A.19).
const cbStyleBypass = 0x01;
const cbStyleReset = 0x02;
const cbStyleTermAll = 0x04;
const cbStyleVerticallyCausal = 0x08;
const cbStyleSegmentationSymbols = 0x20;

/// Sub-band orientation, in the order a resolution level lists its bands.
const orientLL = 0;
const orientHL = 1;
const orientLH = 2;
const orientHH = 3;

// A stripe column's flags. Bit 3 * (r + 1) + c holds the significance of
// row r (-1 to 4: the row above the stripe, its own four, the row below)
// in column c (0 west, 1 this one, 2 east), so shifting the word right by
// 3 * row lines a row's own bits and its eight neighbours' up with row
// 0's, which the constants below describe.
const _sigmaThis = 1 << 4;
const _sigmaNeighbours = 0x1EF;
const _chiThis = 1 << 19; // Negative.
const _muThis = 1 << 20; // Refined.
const _piThis = 1 << 21; // Visited by this bit-plane's significance pass.

// The sign of a coefficient in the stripe above or below is read from that
// stripe's own word rather than copied into this one, which keeps every
// flags word inside 31 bits — a number the web can hold in a machine
// integer.

/// All four rows' own significance bits, and their visited bits.
const _sigmaColumn =
    _sigmaThis | _sigmaThis << 3 | _sigmaThis << 6 | _sigmaThis << 9;
const _piColumn = _piThis | _piThis << 3 | _piThis << 6 | _piThis << 9;

/// Zero-coding context (Table D.1) for each neighbourhood — a row's flags
/// masked with [_sigmaNeighbours] — one 512-entry table per orientation
/// group: LL and LH, HL, HH.
final Uint8List _zcLut = () {
  final lut = Uint8List(3 * 512);
  for (var f = 0; f < 512; f++) {
    int bit(int b) => (f >> b) & 1;
    final h = bit(3) + bit(5);
    final v = bit(1) + bit(7);
    final d = bit(0) + bit(2) + bit(6) + bit(8);
    lut[f] = _zcContext(h, v, d);
    lut[512 + f] = _zcContext(v, h, d);
    final hv = h + v;
    lut[1024 + f] = d >= 3
        ? 8
        : d == 2
        ? (hv >= 1 ? 7 : 6)
        : d == 1
        ? (hv >= 2 ? 5 : (hv == 1 ? 4 : 3))
        : (hv >= 2 ? 2 : hv);
  }
  return lut;
}();

int _zcContext(int h, int v, int d) {
  if (h == 2) return 8;
  if (h == 1) return v >= 1 ? 7 : (d >= 1 ? 6 : 5);
  if (v == 2) return 4;
  if (v == 1) return 3;
  return d >= 2 ? 2 : d;
}

/// An orientation's zero-coding table.
Uint8List _zcTable(int orientation) {
  final group = orientation == orientHL
      ? 1
      : orientation == orientHH
      ? 2
      : 0;
  return Uint8List.sublistView(_zcLut, 512 * group, 512 * group + 512);
}

/// Sign-coding context and XOR bit (Table D.3), packed as `context << 1 |
/// xor`, for every [_signIndex].
final Uint8List _scLut = () {
  final lut = Uint8List(256);
  for (var lu = 0; lu < 256; lu++) {
    int contribution(int sigma, int chi) =>
        (lu >> sigma) & 1 == 0 ? 0 : ((lu >> chi) & 1 == 1 ? -1 : 1);
    final h = contribution(3, 0) + contribution(5, 2);
    final v = contribution(1, 4) + contribution(7, 6);
    if (h == 0) {
      lut[lu] = v == 0 ? 9 << 1 : (10 << 1) | (v < 0 ? 1 : 0);
    } else {
      final vc = v == 0 ? 12 : (v > 0 ? 13 : 11);
      lut[lu] = h > 0
          ? vc << 1
          : ((vc == 12 ? 12 : (vc == 13 ? 11 : 13)) << 1) | 1;
    }
  }
  return lut;
}();

/// The four direct neighbours of the row at shift [s3] (3 * its index) of
/// the stripe column at [i], whose flags are [f], indexed as [_scLut]
/// expects: the significance of north (bit 1), west (3), east (5) and
/// south (7), and their signs in bits 4, 0, 2 and 6. Each sign is read
/// from the word of the column, or the stripe, the neighbour is itself in.
@pragma('vm:prefer-inline')
@pragma('dart2js:prefer-inline')
int _signIndex(Uint32List flags, int stride, int i, int f, int s3) {
  return ((f >> s3) & 0xAA) |
      ((flags[i - 1] >> (19 + s3)) & 1) |
      ((flags[i + 1] >> (17 + s3)) & 4) |
      (s3 == 0 ? (flags[i - stride] >> 24) & 16 : (f >> (12 + s3)) & 16) |
      (s3 == 9 ? (flags[i + stride] >> 13) & 64 : (f >> (16 + s3)) & 64);
}

/// Stripe-column flags for a `width x height` code-block, padded with a
/// column on either side and a stripe above and below, so marking a
/// coefficient's neighbours never needs a bounds check.
Uint32List _newFlags(int width, int height) =>
    Uint32List((width + 2) * (((height + 3) >> 2) + 2));

/// Marks the row at shift [s3] of the stripe column at [i], whose flags
/// are [f],
/// significant with sign [negative] (0 or 1) in its neighbouring columns'
/// and stripes' flags, and returns [f] updated. Under vertically [causal]
/// context formation the stripe above is never told.
@pragma('vm:prefer-inline')
@pragma('dart2js:prefer-inline')
int _markSignificant(
  Uint32List flags,
  int stride,
  int f,
  int i,
  int s3,
  int negative,
  bool causal,
) {
  flags[i - 1] |= (1 << 5) << s3;
  flags[i + 1] |= (1 << 3) << s3;
  if (s3 == 0) {
    if (!causal) {
      // The stripe above sees it as its row 4.
      final north = i - stride;
      flags[north] |= 1 << 16;
      flags[north - 1] |= 1 << 17;
      flags[north + 1] |= 1 << 15;
    }
  } else if (s3 == 9) {
    final south = i + stride;
    flags[south] |= 1 << 1;
    flags[south - 1] |= 1 << 2;
    flags[south + 1] |= 1;
  }
  return f | ((_chiThis * negative | _sigmaThis) << s3);
}

/// One contiguous run of coding passes coded as a unit (a codeword
/// segment), and where its bytes sit in the code-block's data.
typedef CodewordSegment = ({int passes, int start, int length});

/// Decodes a code-block's coding passes into [out] (`width * height`,
/// row-major): each coefficient's magnitude, reconstructed at the middle of
/// its uncertainty interval, in units of half a quantization step — i.e.
/// twice the quantization index — and negated for negative coefficients.
///
/// [bitPlanes] is the sub-band's magnitude bit-plane count (Mb, plus any ROI
/// shift); the first [zeroBitPlanes] of them are all zero and not coded.
/// Decoding is fastest when each segment in [data] is followed by
/// [segmentPadding] 0xFF bytes, as code-block data collected from packets
/// is.
void decodeCodeBlock({
  required Int32List out,
  required int width,
  required int height,
  required int orientation,
  required int cbStyle,
  required int bitPlanes,
  required int zeroBitPlanes,
  required int passes,
  required Uint8List data,
  required List<CodewordSegment> segments,
}) {
  out.fillRange(0, width * height, 0);
  final top = bitPlanes - 1 - zeroBitPlanes;
  if (top < 0 || passes == 0 || segments.isEmpty) return;

  final d = _T1Decoder(out, width, height, orientation, cbStyle);
  final bypass = (cbStyle & cbStyleBypass) != 0;
  var segment = -1;
  var segmentPassesLeft = 0;
  for (var pass = 0; pass < passes; pass++) {
    final bitPlane = top - (pass + 2) ~/ 3;
    if (bitPlane < 0) break;
    final type = pass == 0 ? 2 : (pass - 1) % 3; // 0 SP, 1 MR, 2 cleanup
    final isRaw = bypass && pass >= 10 && type != 2;
    if (segmentPassesLeft == 0) {
      segment++;
      if (segment >= segments.length) break;
      final s = segments[segment];
      segmentPassesLeft = s.passes;
      if (isRaw) {
        d.raw.start(data, s.start, s.start + s.length);
      } else {
        d.start(data, s.start, s.start + s.length);
      }
    }
    if (pass > 0 && (cbStyle & cbStyleReset) != 0) {
      resetMqContexts(d.contexts);
    }
    switch (type) {
      case 0 when isRaw:
        d.rawSignificancePass(bitPlane);
      case 0:
        d.significancePass(bitPlane);
      case 1 when isRaw:
        d.rawRefinementPass(bitPlane);
      case 1:
        d.refinementPass(bitPlane);
      default:
        d.cleanupPass(bitPlane);
        if ((cbStyle & cbStyleSegmentationSymbols) != 0) {
          for (var k = 0; k < 4; k++) {
            d.decode(d.contexts, ctxUniform);
          }
        }
    }
    segmentPassesLeft--;
  }
}

class _T1Decoder extends MqDecoder {
  final Int32List out;
  final int width;
  final int height;
  final int stride;
  final Uint32List flags;
  final Uint8List zc;
  final Uint8List sc = _scLut;
  final bool causal;
  final MqContexts contexts = newMqContexts();
  final raw = RawBitDecoder();

  _T1Decoder(this.out, this.width, this.height, int orientation, int cbStyle)
    : stride = width + 2,
      flags = _newFlags(width, height),
      zc = _zcTable(orientation),
      causal = (cbStyle & cbStyleVerticallyCausal) != 0;

  /// Codes one coefficient of the significance pass: the row at shift
  /// [s3] of the stripe column at [i], which is sample [o]. Returns the
  /// column's flags [f] updated.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _significanceStep(int f, int i, int s3, int o, int one) {
    final fs = f >> s3;
    if ((fs & (_sigmaThis | _piThis)) != 0 || (fs & _sigmaNeighbours) == 0) {
      return f;
    }
    if (decode(contexts, zc[fs & _sigmaNeighbours]) != 0) {
      final cx = sc[_signIndex(flags, stride, i, f, s3)];
      final negative = decode(contexts, cx >> 1) ^ (cx & 1);
      out[o] = negative != 0 ? -one : one;
      f = _markSignificant(flags, stride, f, i, s3, negative, causal);
    }
    return f | (_piThis << s3);
  }

  void significancePass(int bitPlane) {
    final flags = this.flags;
    final w = width, h = height, stride = this.stride;
    final one = 3 << bitPlane;
    for (var y0 = 0, i0 = stride + 1; y0 < h; y0 += 4, i0 += stride) {
      final rows = h - y0 < 4 ? h - y0 : 4;
      final o0 = y0 * w;
      if (rows == 4) {
        // A whole stripe, with each row's shift a constant.
        for (var x = 0; x < w; x++) {
          final i = i0 + x;
          var f = flags[i];
          if (f == 0) continue;
          final o = o0 + x;
          f = _significanceStep(f, i, 0, o, one);
          f = _significanceStep(f, i, 3, o + w, one);
          f = _significanceStep(f, i, 6, o + 2 * w, one);
          f = _significanceStep(f, i, 9, o + 3 * w, one);
          flags[i] = f;
        }
        continue;
      }
      for (var x = 0; x < w; x++) {
        final i = i0 + x;
        var f = flags[i];
        if (f == 0) continue;
        var o = o0 + x;
        for (var s3 = 0; s3 < 3 * rows; s3 += 3, o += w) {
          f = _significanceStep(f, i, s3, o, one);
        }
        flags[i] = f;
      }
    }
  }

  void rawSignificancePass(int bitPlane) {
    final flags = this.flags, out = this.out, raw = this.raw;
    final w = width, h = height, stride = this.stride, causal = this.causal;
    final one = 3 << bitPlane;
    for (var y0 = 0, i0 = stride + 1; y0 < h; y0 += 4, i0 += stride) {
      final rows3 = (h - y0 < 4 ? h - y0 : 4) * 3;
      for (var x = 0; x < w; x++) {
        final i = i0 + x;
        var f = flags[i];
        if (f == 0) continue;
        var o = y0 * w + x;
        for (var s3 = 0; s3 < rows3; s3 += 3, o += w) {
          final fs = f >> s3;
          if ((fs & (_sigmaThis | _piThis)) != 0 ||
              (fs & _sigmaNeighbours) == 0) {
            continue;
          }
          if (raw.decode() != 0) {
            final negative = raw.decode();
            out[o] = negative != 0 ? -one : one;
            f = _markSignificant(flags, stride, f, i, s3, negative, causal);
          }
          f |= _piThis << s3;
        }
        flags[i] = f;
      }
    }
  }

  /// Codes one coefficient of the magnitude refinement pass.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _refinementStep(int f, int s3, int o, int half) {
    final fs = f >> s3;
    if ((fs & (_sigmaThis | _piThis)) != _sigmaThis) return f;
    final cx = (fs & _muThis) != 0
        ? 16
        : ((fs & _sigmaNeighbours) != 0 ? 15 : 14);
    final delta = decode(contexts, cx) != 0 ? half : -half;
    final v = out[o];
    out[o] = v < 0 ? v - delta : v + delta;
    return f | (_muThis << s3);
  }

  void refinementPass(int bitPlane) {
    final flags = this.flags;
    final w = width, h = height, stride = this.stride;
    final half = 1 << bitPlane;
    for (var y0 = 0, i0 = stride + 1; y0 < h; y0 += 4, i0 += stride) {
      final rows = h - y0 < 4 ? h - y0 : 4;
      final o0 = y0 * w;
      if (rows == 4) {
        for (var x = 0; x < w; x++) {
          final i = i0 + x;
          var f = flags[i];
          if ((f & _sigmaColumn) == 0) continue;
          final o = o0 + x;
          f = _refinementStep(f, 0, o, half);
          f = _refinementStep(f, 3, o + w, half);
          f = _refinementStep(f, 6, o + 2 * w, half);
          f = _refinementStep(f, 9, o + 3 * w, half);
          flags[i] = f;
        }
        continue;
      }
      for (var x = 0; x < w; x++) {
        final i = i0 + x;
        var f = flags[i];
        if ((f & _sigmaColumn) == 0) continue;
        var o = o0 + x;
        for (var s3 = 0; s3 < 3 * rows; s3 += 3, o += w) {
          f = _refinementStep(f, s3, o, half);
        }
        flags[i] = f;
      }
    }
  }

  void rawRefinementPass(int bitPlane) {
    final flags = this.flags, out = this.out, raw = this.raw;
    final w = width, h = height, stride = this.stride;
    final half = 1 << bitPlane;
    for (var y0 = 0, i0 = stride + 1; y0 < h; y0 += 4, i0 += stride) {
      final rows3 = (h - y0 < 4 ? h - y0 : 4) * 3;
      for (var x = 0; x < w; x++) {
        final i = i0 + x;
        var f = flags[i];
        if ((f & _sigmaColumn) == 0) continue;
        var o = y0 * w + x;
        for (var s3 = 0; s3 < rows3; s3 += 3, o += w) {
          if (((f >> s3) & (_sigmaThis | _piThis)) != _sigmaThis) continue;
          final delta = raw.decode() != 0 ? half : -half;
          final v = out[o];
          out[o] = v < 0 ? v - delta : v + delta;
          f |= _muThis << s3;
        }
        flags[i] = f;
      }
    }
  }

  /// Codes one coefficient of the cleanup pass, which codes whatever the
  /// significance pass did not visit.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _cleanupStep(int f, int i, int s3, int o, int one) {
    final fs = f >> s3;
    if ((fs & (_sigmaThis | _piThis)) != 0) return f;
    if (decode(contexts, zc[fs & _sigmaNeighbours]) == 0) return f;
    return _sign(f, i, s3, o, one);
  }

  /// Decodes the sign of the coefficient that just turned significant,
  /// writes it out and marks it.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _sign(int f, int i, int s3, int o, int one) {
    final cx = sc[_signIndex(flags, stride, i, f, s3)];
    final negative = decode(contexts, cx >> 1) ^ (cx & 1);
    out[o] = negative != 0 ? -one : one;
    return _markSignificant(flags, stride, f, i, s3, negative, causal);
  }

  void cleanupPass(int bitPlane) {
    final flags = this.flags;
    final contexts = this.contexts;
    final w = width, h = height, stride = this.stride;
    final one = 3 << bitPlane;
    for (var y0 = 0, i0 = stride + 1; y0 < h; y0 += 4, i0 += stride) {
      final rows = h - y0 < 4 ? h - y0 : 4;
      final o0 = y0 * w;
      for (var x = 0; x < w; x++) {
        final i = i0 + x;
        var f = flags[i];
        final o = o0 + x;
        if (f == 0 && rows == 4) {
          // Run-length mode: a whole insignificant, unvisited, neighbour-
          // free column is one symbol, plus where its first significant
          // coefficient is.
          if (decode(contexts, ctxRunLength) == 0) continue;
          final run =
              (decode(contexts, ctxUniform) << 1) |
              decode(contexts, ctxUniform);
          f = _sign(f, i, 3 * run, o + run * w, one);
          for (
            var s3 = 3 * run + 3, p = o + run * w + w;
            s3 < 12;
            s3 += 3, p += w
          ) {
            f = _cleanupStep(f, i, s3, p, one);
          }
          flags[i] = f & ~_piColumn;
          continue;
        }
        if (rows == 4) {
          f = _cleanupStep(f, i, 0, o, one);
          f = _cleanupStep(f, i, 3, o + w, one);
          f = _cleanupStep(f, i, 6, o + 2 * w, one);
          f = _cleanupStep(f, i, 9, o + 3 * w, one);
        } else {
          for (var s3 = 0, p = o; s3 < 3 * rows; s3 += 3, p += w) {
            f = _cleanupStep(f, i, s3, p, one);
          }
        }
        flags[i] = f & ~_piColumn;
      }
    }
  }
}

/// A code-block's MQ codeword plus, for rate allocation, how long it has to
/// be to include each coding pass and how much each pass lowers the
/// squared error (in squared quantization steps).
class EncodedCodeBlock {
  /// Magnitude bit-planes actually coded: all bit-planes below the
  /// code-block's highest non-zero bit.
  final int bitPlanes;
  final Uint8List data;

  /// Cumulative codeword length after each pass, non-decreasing, the last
  /// equal to `data.length`.
  final List<int> passLengths;

  /// Cumulative squared-error reduction after each pass.
  final List<double> passDistortions;

  const EncodedCodeBlock(
    this.bitPlanes,
    this.data,
    this.passLengths,
    this.passDistortions,
  );

  int get passes => passLengths.length;
}

/// Encodes a code-block with the default style (one MQ codeword, no
/// bypass, termination, reset or causal contexts). [indices] are the
/// quantization indices (`width * height`, row-major, negative for negative
/// coefficients). [magnitudes], if given, are the exact magnitudes they were
/// quantized from, in quantization steps: each pass's distortion reduction
/// is measured against them for rate allocation. Without them (lossless
/// coding, which keeps every pass) distortions are left at zero.
EncodedCodeBlock encodeCodeBlock({
  required Int32List indices,
  required int width,
  required int height,
  required int orientation,
  Float64List? magnitudes,
}) {
  final n = width * height;
  final absolute = Int32List(n);
  final maxMagnitude = _magnitudes(indices, absolute, n);
  if (maxMagnitude == 0) {
    return EncodedCodeBlock(0, Uint8List(0), const [], const []);
  }
  final bitPlanes = maxMagnitude.bitLength;
  final e = _T1Encoder(
    indices,
    absolute,
    magnitudes ?? Float64List(0),
    magnitudes != null,
    width,
    height,
    orientation,
  );
  final lengths = <int>[];
  final distortions = <double>[];
  for (var bitPlane = bitPlanes - 1; bitPlane >= 0; bitPlane--) {
    for (var type = bitPlane == bitPlanes - 1 ? 2 : 0; type < 3; type++) {
      switch (type) {
        case 0:
          e.significancePass(bitPlane);
        case 1:
          e.refinementPass(bitPlane);
        default:
          e.cleanupPass(bitPlane);
      }
      // A pass can be cut off once its bytes plus what's still pending in
      // the coder's registers are in; two bytes more than written so far
      // always covers that.
      lengths.add(e.bytes + 2);
      distortions.add(e.distortion);
    }
  }

  final data = e.finish();
  for (var k = 0; k < lengths.length; k++) {
    if (lengths[k] > data.length) lengths[k] = data.length;
    // Never end a truncated codeword on 0xFF: followed by the next
    // code-block's bytes, it could read as a marker.
    if (lengths[k] > 0 && data[lengths[k] - 1] == 0xFF) lengths[k]--;
  }
  lengths[lengths.length - 1] = data.length;
  for (var k = lengths.length - 2; k >= 0; k--) {
    if (lengths[k] > lengths[k + 1]) lengths[k] = lengths[k + 1];
  }
  return EncodedCodeBlock(bitPlanes, data, lengths, distortions);
}

/// Fills [absolute] with the magnitudes of [indices] and returns the
/// largest of them.
int _magnitudes(Int32List indices, Int32List absolute, int n) {
  var max = 0;
  for (var i = 0; i < n; i++) {
    final v = indices[i];
    final m = v < 0 ? -v : v;
    absolute[i] = m;
    if (m > max) max = m;
  }
  return max;
}

class _T1Encoder extends MqEncoder {
  final Int32List indices;
  final Int32List absolute;

  /// The exact magnitudes the indices were quantized from, if [measure]:
  /// every significance and refinement then adds how much it lowers their
  /// squared error to [distortion], the decoder reconstructing each
  /// magnitude at the middle of the interval its coded bits leave.
  final Float64List magnitudes;
  final bool measure;
  final int width;
  final int height;
  final int stride;
  final Uint32List flags;
  final Uint8List zc;
  final Uint8List sc = _scLut;
  final MqContexts contexts = newMqContexts();
  double distortion = 0;

  _T1Encoder(
    this.indices,
    this.absolute,
    this.magnitudes,
    this.measure,
    this.width,
    this.height,
    int orientation,
  ) : stride = width + 2,
      flags = _newFlags(width, height),
      zc = _zcTable(orientation);

  /// Codes the sign of coefficient [o] — row [ci] of the stripe column at
  /// [i], whose flags are [f] — which turns significant in [bitPlane], and
  /// returns [f] updated.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _significant(int f, int i, int s3, int o, int bitPlane) {
    final negative = indices[o] < 0 ? 1 : 0;
    final cx = sc[_signIndex(flags, stride, i, f, s3)];
    encode(contexts, cx >> 1, negative ^ (cx & 1));
    if (measure) {
      final m = magnitudes[o];
      final value = 1.5 * (1 << bitPlane);
      distortion += m * m - (m - value) * (m - value);
    }
    return _markSignificant(flags, stride, f, i, s3, negative, false);
  }

  /// Codes one coefficient of the significance pass: the row at shift
  /// [s3] of the stripe column at [i], which is coefficient [o].
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _significanceStep(int f, int i, int s3, int o, int bitPlane) {
    final fs = f >> s3;
    if ((fs & (_sigmaThis | _piThis)) != 0 || (fs & _sigmaNeighbours) == 0) {
      return f;
    }
    final bit = (absolute[o] >> bitPlane) & 1;
    encode(contexts, zc[fs & _sigmaNeighbours], bit);
    if (bit != 0) f = _significant(f, i, s3, o, bitPlane);
    return f | (_piThis << s3);
  }

  void significancePass(int bitPlane) {
    final flags = this.flags;
    final w = width, h = height, stride = this.stride;
    for (var y0 = 0, i0 = stride + 1; y0 < h; y0 += 4, i0 += stride) {
      final rows = h - y0 < 4 ? h - y0 : 4;
      final o0 = y0 * w;
      if (rows == 4) {
        // A whole stripe, with each row's shift a constant.
        for (var x = 0; x < w; x++) {
          final i = i0 + x;
          var f = flags[i];
          if (f == 0) continue;
          final o = o0 + x;
          f = _significanceStep(f, i, 0, o, bitPlane);
          f = _significanceStep(f, i, 3, o + w, bitPlane);
          f = _significanceStep(f, i, 6, o + 2 * w, bitPlane);
          f = _significanceStep(f, i, 9, o + 3 * w, bitPlane);
          flags[i] = f;
        }
        continue;
      }
      for (var x = 0; x < w; x++) {
        final i = i0 + x;
        var f = flags[i];
        if (f == 0) continue;
        var o = o0 + x;
        for (var s3 = 0; s3 < 3 * rows; s3 += 3, o += w) {
          f = _significanceStep(f, i, s3, o, bitPlane);
        }
        flags[i] = f;
      }
    }
  }

  /// Codes one coefficient of the magnitude refinement pass.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _refinementStep(int f, int s3, int o, int bitPlane, double half) {
    final fs = f >> s3;
    if ((fs & (_sigmaThis | _piThis)) != _sigmaThis) return f;
    final q = absolute[o];
    final bit = (q >> bitPlane) & 1;
    encode(
      contexts,
      (fs & _muThis) != 0 ? 16 : ((fs & _sigmaNeighbours) != 0 ? 15 : 14),
      bit,
    );
    if (measure) {
      // What the decoder had reconstructed before this bit, and has after
      // it: the bits above it, plus half the interval each leaves.
      final m = magnitudes[o];
      final before = ((q >> (bitPlane + 1)) << (bitPlane + 1)) + 2.0 * half;
      final after = before + (bit != 0 ? half : -half);
      distortion += (m - before) * (m - before) - (m - after) * (m - after);
    }
    return f | (_muThis << s3);
  }

  void refinementPass(int bitPlane) {
    final flags = this.flags;
    final w = width, h = height, stride = this.stride;
    final half = 0.5 * (1 << bitPlane);
    for (var y0 = 0, i0 = stride + 1; y0 < h; y0 += 4, i0 += stride) {
      final rows = h - y0 < 4 ? h - y0 : 4;
      final o0 = y0 * w;
      if (rows == 4) {
        for (var x = 0; x < w; x++) {
          final i = i0 + x;
          var f = flags[i];
          if ((f & _sigmaColumn) == 0) continue;
          final o = o0 + x;
          f = _refinementStep(f, 0, o, bitPlane, half);
          f = _refinementStep(f, 3, o + w, bitPlane, half);
          f = _refinementStep(f, 6, o + 2 * w, bitPlane, half);
          f = _refinementStep(f, 9, o + 3 * w, bitPlane, half);
          flags[i] = f;
        }
        continue;
      }
      for (var x = 0; x < w; x++) {
        final i = i0 + x;
        var f = flags[i];
        if ((f & _sigmaColumn) == 0) continue;
        var o = o0 + x;
        for (var s3 = 0; s3 < 3 * rows; s3 += 3, o += w) {
          f = _refinementStep(f, s3, o, bitPlane, half);
        }
        flags[i] = f;
      }
    }
  }

  /// Codes one coefficient of the cleanup pass, which codes whatever the
  /// significance pass did not visit.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _cleanupStep(int f, int i, int s3, int o, int bitPlane) {
    final fs = f >> s3;
    if ((fs & (_sigmaThis | _piThis)) != 0) return f;
    final bit = (absolute[o] >> bitPlane) & 1;
    encode(contexts, zc[fs & _sigmaNeighbours], bit);
    if (bit != 0) f = _significant(f, i, s3, o, bitPlane);
    return f;
  }

  void cleanupPass(int bitPlane) {
    final flags = this.flags, absolute = this.absolute;
    final contexts = this.contexts;
    final w = width, h = height, stride = this.stride;
    for (var y0 = 0, i0 = stride + 1; y0 < h; y0 += 4, i0 += stride) {
      final rows = h - y0 < 4 ? h - y0 : 4;
      final o0 = y0 * w;
      for (var x = 0; x < w; x++) {
        final i = i0 + x;
        var f = flags[i];
        final o = o0 + x;
        if (f == 0 && rows == 4) {
          var run = 0;
          while (run < 4 && (absolute[o + run * w] >> bitPlane) & 1 == 0) {
            run++;
          }
          if (run == 4) {
            encode(contexts, ctxRunLength, 0);
            continue;
          }
          encode(contexts, ctxRunLength, 1);
          encode(contexts, ctxUniform, run >> 1);
          encode(contexts, ctxUniform, run & 1);
          f = _significant(f, i, 3 * run, o + run * w, bitPlane);
          for (
            var s3 = 3 * run + 3, p = o + run * w + w;
            s3 < 12;
            s3 += 3, p += w
          ) {
            f = _cleanupStep(f, i, s3, p, bitPlane);
          }
          flags[i] = f & ~_piColumn;
          continue;
        }
        if (rows == 4) {
          f = _cleanupStep(f, i, 0, o, bitPlane);
          f = _cleanupStep(f, i, 3, o + w, bitPlane);
          f = _cleanupStep(f, i, 6, o + 2 * w, bitPlane);
          f = _cleanupStep(f, i, 9, o + 3 * w, bitPlane);
        } else {
          for (var s3 = 0, p = o; s3 < 3 * rows; s3 += 3, p += w) {
            f = _cleanupStep(f, i, s3, p, bitPlane);
          }
        }
        flags[i] = f & ~_piColumn;
      }
    }
  }
}
