// The discrete wavelet transforms of ISO/IEC 15444-1 Annex F: one
// decomposition level at a time, as in-place lifting over the rows, then
// the columns (or the reverse), of a level's samples. Which samples are
// low-pass depends on their absolute coordinate's parity (even = low), so a
// level's bounds are always passed as its absolute [x0, x1) x [y0, y1).
//
// The 5/3 lifting steps shift sums that can be negative. On the web the
// shift operators work on unsigned 32-bit values, so such a shift comes
// back 2^32 too large — which the Int32List the result is stored back into
// takes straight off again, leaving every platform the same samples.
//
// Whole-sample symmetric extension is applied by mirroring a lifting step's
// neighbour index at the edges (x[-1] = x[1], x[n] = x[n - 2]): the
// extension stays symmetric after every lifting step, so this is exact.
// Columns are lifted a whole row at a time, which keeps memory access
// sequential and lets two columns go through the vector unit at once where
// one is available.
//
// The 9/7's two scaling steps are not applied here: they scale a level's
// low-pass samples by K and its high-pass ones by 1/K, which is one factor
// per sub-band ([gain97]) that the caller folds into whatever it already
// scales a band's samples by.
import 'dart:typed_data';

import 'tier1.dart' show orientHH, orientHL, orientLH, orientLL;

// Irreversible 9/7 lifting constants (Table F.4).
const _alpha = -1.586134342059924;
const _beta = -0.052980118572961;
const _gamma = 0.882911075530934;
const _delta = 0.443506852043971;
const _k = 1.230174104914001;
const _invK = 1 / _k;

/// Whether to lift columns through `Float64x2`: only where it is a vector
/// register, which is everywhere but the web, where it is a class.
const _vectors = bool.fromEnvironment('dart.library.io');

/// Samples of [i0, i1) that are low-pass (even) and high-pass (odd).
int lowCount(int i0, int i1) => ((i1 + 1) >> 1) - ((i0 + 1) >> 1);
int highCount(int i0, int i1) => (i1 >> 1) - (i0 >> 1);

/// One level's four sub-bands, each row-major at its own size.
class SubBands<T extends List<num>> {
  final T ll;
  final T hl;
  final T lh;
  final T hh;

  const SubBands(this.ll, this.hl, this.lh, this.hh);
}

/// The column and row of a level that band [orientation] starts at, given
/// the level's origin ([x0], [y0]): its samples are every other one from
/// there.
(int, int) bandOrigin(int orientation, int x0, int y0) => (
  (orientation & 1) != 0 ? 1 - (x0 & 1) : x0 & 1,
  (orientation & 2) != 0 ? 1 - (y0 & 1) : y0 & 1,
);

/// K to the power -2 to 2.
const _powersOfK = [_invK * _invK, _invK, 1.0, _k, _k * _k];

/// What band [orientation] of a `width x height` level must be scaled by
/// before [inverse97InPlace]: the 9/7's scaling steps (F.3.8.2) are one
/// constant per band — K for each direction the band is low-pass in, 1/K
/// for each it is high-pass in — except that a side of a single sample is
/// halved instead (F.3.7).
double gain97(int orientation, int width, int height) {
  var power = 0;
  var scale = 1.0;
  final horizontallyHigh = (orientation & 1) != 0;
  final verticallyHigh = (orientation & 2) != 0;
  if (width == 1) {
    if (horizontallyHigh) scale = 0.5;
  } else {
    power += horizontallyHigh ? -1 : 1;
  }
  if (height == 1) {
    if (verticallyHigh) scale *= 0.5;
  } else {
    power += verticallyHigh ? -1 : 1;
  }
  return scale * _powersOfK[power + 2];
}

// --- 1D lifting along a row -------------------------------------------------

/// `x[i] += sign * ((x[i-1] + x[i+1] + 2) >> 2)` over every other sample
/// from [first], neighbours mirrored at the edges.
void _liftRow53Even(Int32List a, int base, int n, int first, int sign) {
  var i = first;
  if (i == 0) {
    a[base] += sign * ((2 * a[base + 1] + 2) >> 2);
    i = 2;
  }
  final last = n - 1;
  var prev = a[base + i - 1];
  for (; i < last; i += 2) {
    final o = base + i;
    final next = a[o + 1];
    a[o] += sign * ((prev + next + 2) >> 2);
    prev = next;
  }
  if (i == last) a[base + last] += sign * ((2 * prev + 2) >> 2);
}

/// `x[i] += sign * ((x[i-1] + x[i+1]) >> 1)`, likewise.
void _liftRow53Odd(Int32List a, int base, int n, int first, int sign) {
  var i = first;
  if (i == 0) {
    a[base] += sign * a[base + 1];
    i = 2;
  }
  final last = n - 1;
  var prev = a[base + i - 1];
  for (; i < last; i += 2) {
    final o = base + i;
    final next = a[o + 1];
    a[o] += sign * ((prev + next) >> 1);
    prev = next;
  }
  if (i == last) a[base + last] += sign * prev;
}

/// `x[i] += c * (x[i-1] + x[i+1])`, likewise.
void _liftRow97(Float64List a, int base, int n, int first, double c) {
  var i = first;
  if (i == 0) {
    a[base] += 2 * c * a[base + 1];
    i = 2;
  }
  final last = n - 1;
  var prev = a[base + i - 1];
  for (; i < last; i += 2) {
    final o = base + i;
    final next = a[o + 1];
    a[o] += c * (prev + next);
    prev = next;
  }
  if (i == last) a[base + last] += 2 * c * prev;
}

void _scaleRow(Float64List a, int base, int n, int first, double c) {
  for (var i = first; i < n; i += 2) {
    a[base + i] *= c;
  }
}

// --- 1D lifting down the columns, a whole row at a time ----------------------

int _mirror(int j, int n) => j < 0 ? -j : (j >= n ? 2 * (n - 1) - j : j);

void _liftCols53(
  Int32List a,
  int w,
  int h,
  int first,
  bool evenStep,
  int sign,
) {
  for (var j = first; j < h; j += 2) {
    final row = j * w;
    final up = _mirror(j - 1, h) * w;
    final down = _mirror(j + 1, h) * w;
    if (evenStep) {
      if (sign > 0) {
        for (var i = 0; i < w; i++) {
          a[row + i] += (a[up + i] + a[down + i] + 2) >> 2;
        }
      } else {
        for (var i = 0; i < w; i++) {
          a[row + i] -= (a[up + i] + a[down + i] + 2) >> 2;
        }
      }
    } else {
      if (sign > 0) {
        for (var i = 0; i < w; i++) {
          a[row + i] += (a[up + i] + a[down + i]) >> 1;
        }
      } else {
        for (var i = 0; i < w; i++) {
          a[row + i] -= (a[up + i] + a[down + i]) >> 1;
        }
      }
    }
  }
}

void _liftCols97(Float64List a, int w, int h, int first, double c) {
  if (_vectors && (w & 1) == 0 && (a.offsetInBytes & 15) == 0) {
    _liftCols97Vector(
      Float64x2List.view(a.buffer, a.offsetInBytes, a.length >> 1),
      w >> 1,
      h,
      first,
      c,
    );
    return;
  }
  for (var j = first; j < h; j += 2) {
    final row = j * w;
    final up = _mirror(j - 1, h) * w;
    final down = _mirror(j + 1, h) * w;
    for (var i = 0; i < w; i++) {
      a[row + i] += c * (a[up + i] + a[down + i]);
    }
  }
}

/// [_liftCols97] over a row of `Float64x2` pairs — the same arithmetic in
/// the same order, two columns at a time.
void _liftCols97Vector(Float64x2List a, int w, int h, int first, double c) {
  final cc = Float64x2.splat(c);
  for (var j = first; j < h; j += 2) {
    final row = j * w;
    final up = _mirror(j - 1, h) * w;
    final down = _mirror(j + 1, h) * w;
    for (var i = 0; i < w; i++) {
      a[row + i] += cc * (a[up + i] + a[down + i]);
    }
  }
}

void _scaleCols(Float64List a, int w, int h, int first, double c) {
  for (var j = first; j < h; j += 2) {
    final row = j * w;
    for (var i = 0; i < w; i++) {
      a[row + i] *= c;
    }
  }
}

// --- Whole-level passes -------------------------------------------------------

void _inverse53Rows(Int32List a, int w, int h, int x0) {
  if (w == 1) {
    if (x0.isOdd) {
      for (var j = 0; j < h; j++) {
        a[j * w] = a[j * w] ~/ 2;
      }
    }
    return;
  }
  final even = x0 & 1;
  for (var j = 0; j < h; j++) {
    final base = j * w;
    _liftRow53Even(a, base, w, even, -1);
    _liftRow53Odd(a, base, w, 1 - even, 1);
  }
}

void _inverse53Cols(Int32List a, int w, int h, int y0) {
  if (h == 1) {
    if (y0.isOdd) {
      for (var i = 0; i < w; i++) {
        a[i] = a[i] ~/ 2;
      }
    }
    return;
  }
  final even = y0 & 1;
  _liftCols53(a, w, h, even, true, -1);
  _liftCols53(a, w, h, 1 - even, false, 1);
}

void _forward53Rows(Int32List a, int w, int h, int x0) {
  if (w == 1) {
    if (x0.isOdd) {
      for (var j = 0; j < h; j++) {
        a[j * w] *= 2;
      }
    }
    return;
  }
  final even = x0 & 1;
  for (var j = 0; j < h; j++) {
    final base = j * w;
    _liftRow53Odd(a, base, w, 1 - even, -1);
    _liftRow53Even(a, base, w, even, 1);
  }
}

void _forward53Cols(Int32List a, int w, int h, int y0) {
  if (h == 1) {
    if (y0.isOdd) {
      for (var i = 0; i < w; i++) {
        a[i] *= 2;
      }
    }
    return;
  }
  final even = y0 & 1;
  _liftCols53(a, w, h, 1 - even, false, -1);
  _liftCols53(a, w, h, even, true, 1);
}

void _inverse97Rows(Float64List a, int w, int h, int x0) {
  if (w == 1) return; // Scaled by gain97 instead.
  final even = x0 & 1;
  final odd = 1 - even;
  for (var j = 0; j < h; j++) {
    final base = j * w;
    _liftRow97(a, base, w, even, -_delta);
    _liftRow97(a, base, w, odd, -_gamma);
    _liftRow97(a, base, w, even, -_beta);
    _liftRow97(a, base, w, odd, -_alpha);
  }
}

void _inverse97Cols(Float64List a, int w, int h, int y0) {
  if (h == 1) return;
  final even = y0 & 1;
  final odd = 1 - even;
  _liftCols97(a, w, h, even, -_delta);
  _liftCols97(a, w, h, odd, -_gamma);
  _liftCols97(a, w, h, even, -_beta);
  _liftCols97(a, w, h, odd, -_alpha);
}

void _forward97Rows(Float64List a, int w, int h, int x0) {
  final even = x0 & 1;
  final odd = 1 - even;
  for (var j = 0; j < h; j++) {
    final base = j * w;
    if (w == 1) {
      if (x0.isOdd) a[base] *= 2;
      continue;
    }
    _liftRow97(a, base, w, odd, _alpha);
    _liftRow97(a, base, w, even, _beta);
    _liftRow97(a, base, w, odd, _gamma);
    _liftRow97(a, base, w, even, _delta);
    _scaleRow(a, base, w, even, _invK);
    _scaleRow(a, base, w, odd, _k);
  }
}

void _forward97Cols(Float64List a, int w, int h, int y0) {
  if (h == 1) {
    if (y0.isOdd) {
      for (var i = 0; i < w; i++) {
        a[i] *= 2;
      }
    }
    return;
  }
  final even = y0 & 1;
  final odd = 1 - even;
  _liftCols97(a, w, h, odd, _alpha);
  _liftCols97(a, w, h, even, _beta);
  _liftCols97(a, w, h, odd, _gamma);
  _liftCols97(a, w, h, even, _delta);
  _scaleCols(a, w, h, even, _invK);
  _scaleCols(a, w, h, odd, _k);
}

// --- Interleaving ---------------------------------------------------------------

// Each band lands on every other sample of the level, from a corner set by
// the level's origin parity. Specialised per list type: through a generic
// List<num> these loops would run several times slower.

/// Writes [src] (`sw x sh`) into every other sample of [out] (`w` wide)
/// from column [ox], row [oy].
void interleaveInts(
  Int32List out,
  int w,
  Int32List src,
  int sw,
  int sh,
  int ox,
  int oy,
) {
  for (var j = 0; j < sh; j++) {
    final o = (oy + 2 * j) * w + ox;
    final s = j * sw;
    for (var i = 0; i < sw; i++) {
      out[o + 2 * i] = src[s + i];
    }
  }
}

/// Same as [interleaveInts], scaling each sample by [gain].
void interleaveFloats(
  Float64List out,
  int w,
  Float64List src,
  int sw,
  int sh,
  int ox,
  int oy,
  double gain,
) {
  for (var j = 0; j < sh; j++) {
    final o = (oy + 2 * j) * w + ox;
    final s = j * sw;
    for (var i = 0; i < sw; i++) {
      out[o + 2 * i] = src[s + i] * gain;
    }
  }
}

void _gatherInts(
  Int32List src,
  int w,
  Int32List out,
  int ow,
  int oh,
  int ox,
  int oy,
) {
  for (var j = 0; j < oh; j++) {
    final s = (oy + 2 * j) * w + ox;
    final o = j * ow;
    for (var i = 0; i < ow; i++) {
      out[o + i] = src[s + 2 * i];
    }
  }
}

void _gatherFloats(
  Float64List src,
  int w,
  Float64List out,
  int ow,
  int oh,
  int ox,
  int oy,
) {
  for (var j = 0; j < oh; j++) {
    final s = (oy + 2 * j) * w + ox;
    final o = j * ow;
    for (var i = 0; i < ow; i++) {
      out[o + i] = src[s + 2 * i];
    }
  }
}

/// Band sizes and corner offsets of a level: `(lw, hw, lh, hh, lx, hx, ly,
/// hy)` — low/high widths, heights, and the column/row each starts at.
(int, int, int, int, int, int, int, int) _layout(
  int x0,
  int y0,
  int x1,
  int y1,
) {
  final lx = x0 & 1, ly = y0 & 1;
  return (
    lowCount(x0, x1),
    highCount(x0, x1),
    lowCount(y0, y1),
    highCount(y0, y1),
    lx,
    1 - lx,
    ly,
    1 - ly,
  );
}

// --- Public API -------------------------------------------------------------------

/// Reconstructs a level spanning [x0, x1) x [y0, y1) with the reversible
/// 5/3 filter (F.3.2), from its sub-bands already interleaved into [a]
/// (see [interleaveInts] and [bandOrigin]). Overwrites [a].
void inverse53InPlace(Int32List a, int x0, int y0, int x1, int y1) {
  final w = x1 - x0, h = y1 - y0;
  if (w == 0 || h == 0) return;
  _inverse53Rows(a, w, h, x0);
  _inverse53Cols(a, w, h, y0);
}

/// Same as [inverse53InPlace], with the irreversible 9/7 filter. Each
/// band's samples must have been scaled by its [gain97] as they were
/// interleaved.
void inverse97InPlace(Float64List a, int x0, int y0, int x1, int y1) {
  final w = x1 - x0, h = y1 - y0;
  if (w == 0 || h == 0) return;
  _inverse97Rows(a, w, h, x0);
  _inverse97Cols(a, w, h, y0);
}

/// Reconstructs a level from its sub-bands with the reversible 5/3 filter.
Int32List inverse53(SubBands<Int32List> bands, int x0, int y0, int x1, int y1) {
  final w = x1 - x0, h = y1 - y0;
  final out = Int32List(w * h);
  if (w == 0 || h == 0) return out;
  final (lw, hw, lh, hh, lx, hx, ly, hy) = _layout(x0, y0, x1, y1);
  interleaveInts(out, w, bands.ll, lw, lh, lx, ly);
  interleaveInts(out, w, bands.hl, hw, lh, hx, ly);
  interleaveInts(out, w, bands.lh, lw, hh, lx, hy);
  interleaveInts(out, w, bands.hh, hw, hh, hx, hy);
  inverse53InPlace(out, x0, y0, x1, y1);
  return out;
}

/// Same as [inverse53], with the irreversible 9/7 filter.
Float64List inverse97(
  SubBands<Float64List> bands,
  int x0,
  int y0,
  int x1,
  int y1,
) {
  final w = x1 - x0, h = y1 - y0;
  final out = Float64List(w * h);
  if (w == 0 || h == 0) return out;
  final (lw, hw, lh, hh, lx, hx, ly, hy) = _layout(x0, y0, x1, y1);
  interleaveFloats(out, w, bands.ll, lw, lh, lx, ly, gain97(orientLL, w, h));
  interleaveFloats(out, w, bands.hl, hw, lh, hx, ly, gain97(orientHL, w, h));
  interleaveFloats(out, w, bands.lh, lw, hh, lx, hy, gain97(orientLH, w, h));
  interleaveFloats(out, w, bands.hh, hw, hh, hx, hy, gain97(orientHH, w, h));
  inverse97InPlace(out, x0, y0, x1, y1);
  return out;
}

/// Decomposes a level spanning [x0, x1) x [y0, y1) into its sub-bands with
/// the reversible 5/3 filter (F.4.2). Overwrites [a].
SubBands<Int32List> forward53(Int32List a, int x0, int y0, int x1, int y1) {
  final w = x1 - x0, h = y1 - y0;
  if (w > 0 && h > 0) {
    _forward53Cols(a, w, h, y0);
    _forward53Rows(a, w, h, x0);
  }
  final (lw, hw, lh, hh, lx, hx, ly, hy) = _layout(x0, y0, x1, y1);
  final b = SubBands(
    Int32List(lw * lh),
    Int32List(hw * lh),
    Int32List(lw * hh),
    Int32List(hw * hh),
  );
  _gatherInts(a, w, b.ll, lw, lh, lx, ly);
  _gatherInts(a, w, b.hl, hw, lh, hx, ly);
  _gatherInts(a, w, b.lh, lw, hh, lx, hy);
  _gatherInts(a, w, b.hh, hw, hh, hx, hy);
  return b;
}

/// Same as [forward53], with the irreversible 9/7 filter.
SubBands<Float64List> forward97(Float64List a, int x0, int y0, int x1, int y1) {
  final w = x1 - x0, h = y1 - y0;
  if (w > 0 && h > 0) {
    _forward97Cols(a, w, h, y0);
    _forward97Rows(a, w, h, x0);
  }
  final (lw, hw, lh, hh, lx, hx, ly, hy) = _layout(x0, y0, x1, y1);
  final b = SubBands(
    Float64List(lw * lh),
    Float64List(hw * lh),
    Float64List(lw * hh),
    Float64List(hw * hh),
  );
  _gatherFloats(a, w, b.ll, lw, lh, lx, ly);
  _gatherFloats(a, w, b.hl, hw, lh, hx, ly);
  _gatherFloats(a, w, b.lh, lw, hh, lx, hy);
  _gatherFloats(a, w, b.hh, hw, hh, hx, hy);
  return b;
}
