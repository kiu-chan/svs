// A JPEG2000 Part 1 codestream encoder for 8-bit rasters: one tile, one
// quality layer, LRCP, 64x64 code-blocks, up to five decomposition levels,
// components coded independently. Lossless uses the reversible 5/3
// wavelet; lossy the irreversible 9/7, with each code-block's coding passes
// truncated by post-compression rate-distortion optimisation to meet a
// target size. These are OpenJPEG's defaults, which this package's exports
// used before it had its own codec.
import 'dart:math' as math;
import 'dart:typed_data';

import 'dwt.dart';
import 'j2k_structure.dart';
import 'tier1.dart';
import 'tier2.dart';

class J2kEncodeException implements Exception {
  final String message;

  const J2kEncodeException(this.message);

  @override
  String toString() => 'J2kEncodeException: $message';
}

const _guardBits = 2;
const _codeBlockExponent = 6; // 64x64
const _maxLevels = 5;

/// Encodes an interleaved, tightly packed 8-bit raster ([width] *
/// [height] * [numComponents] bytes, row-major) as a raw JPEG2000
/// codestream. [numComponents] must be 1-4.
///
/// [compressionRatio] 0 (the default) encodes losslessly; above 0, lossy at
/// that size ratio to the raw raster (e.g. 20 for roughly 20:1 smaller).
Uint8List encodeJ2k(
  Uint8List pixels, {
  required int width,
  required int height,
  required int numComponents,
  double compressionRatio = 0,
}) {
  if (numComponents < 1 || numComponents > 4 || width <= 0 || height <= 0) {
    throw const J2kEncodeException(
      'invalid width/height/numComponents (numComponents must be 1-4)',
    );
  }
  if (pixels.length < width * height * numComponents) {
    throw const J2kEncodeException('pixel buffer is smaller than the raster');
  }
  return _Encoder(
    pixels,
    width,
    height,
    numComponents,
    compressionRatio,
  ).encode();
}

class _Component {
  final List<Resolution> resolutions;

  /// Per band, in resolution order: quantization exponent and mantissa.
  final List<(int, int)> steps;

  _Component(this.resolutions, this.steps);
}

class _Encoder {
  final Uint8List pixels;
  final int width;
  final int height;
  final int count;
  final double ratio;
  final bool reversible;
  final int levels;

  _Encoder(this.pixels, this.width, this.height, this.count, this.ratio)
    : reversible = ratio <= 0,
      levels = _levelsFor(math.min(width, height));

  /// Decomposition levels: five, or fewer so every level of a small raster
  /// keeps at least one sample per side.
  static int _levelsFor(int minDim) {
    var resolutions = 1;
    while ((1 << resolutions) <= minDim) {
      resolutions++;
    }
    return math.min(resolutions, _maxLevels + 1) - 1;
  }

  Uint8List encode() {
    final n = width * height;
    final components = <_Component>[];
    final ints = <Int32List>[];
    final floats = <Float64List>[];
    for (var c = 0; c < count; c++) {
      if (reversible) {
        final a = Int32List(n);
        for (var i = 0; i < n; i++) {
          a[i] = pixels[i * count + c] - 128;
        }
        ints.add(a);
      } else {
        final a = Float64List(n);
        for (var i = 0; i < n; i++) {
          a[i] = pixels[i * count + c] - 128.0;
        }
        floats.add(a);
      }
    }
    for (var c = 0; c < count; c++) {
      final resolutions = buildResolutions(
        x0: 0,
        y0: 0,
        x1: width,
        y1: height,
        levels: levels,
        xcb: _codeBlockExponent,
        ycb: _codeBlockExponent,
        precinctExponents: List.filled(levels + 1, (15, 15)),
      );
      final steps = <(int, int)>[];
      // Forward transform, finest level first; each level's bands keyed by
      // resolution, the last low-pass band being resolution 0's.
      final bandData = List<List<List<num>>>.filled(levels + 1, const []);
      List<num> level = reversible ? ints[c] : floats[c];
      for (var r = levels; r >= 1; r--) {
        final res = resolutions[r];
        if (reversible) {
          final b = forward53(
            level as Int32List,
            res.x0,
            res.y0,
            res.x1,
            res.y1,
          );
          bandData[r] = [b.hl, b.lh, b.hh];
          level = b.ll;
        } else {
          final b = forward97(
            level as Float64List,
            res.x0,
            res.y0,
            res.x1,
            res.y1,
          );
          bandData[r] = [b.hl, b.lh, b.hh];
          level = b.ll;
        }
      }
      bandData[0] = [level];

      for (var r = 0; r <= levels; r++) {
        final res = resolutions[r];
        for (var b = 0; b < res.bands.length; b++) {
          final band = res.bands[b];
          final step = _step(r, band.orientation);
          steps.add(step);
          _encodeBand(band, bandData[r][b], step, c);
        }
      }
      components.add(_Component(resolutions, steps));
    }

    if (!reversible) _allocateRate(components);
    for (final comp in components) {
      for (final res in comp.resolutions) {
        for (final band in res.bands) {
          for (final prc in band.precincts) {
            for (final cb in prc.blocks) {
              if (reversible) cb.includedPasses = cb.encoded!.passes;
            }
          }
        }
      }
    }
    return _write(components);
  }

  int _gain(int orientation) =>
      orientation == orientLL ? 0 : (orientation == orientHH ? 2 : 1);

  /// A band's quantization exponent and mantissa: for the reversible path
  /// just its dynamic range (no quantization); otherwise a step inversely
  /// proportional to the band's synthesis gain, so a unit step costs every
  /// band the same error in the image.
  (int, int) _step(int r, int orientation) {
    final gain = _gain(orientation);
    if (reversible) return (8 + gain, 0);
    final decomposition = r == 0 ? levels : levels - r + 1;
    final step = 1 / _norm97(decomposition, orientation);
    final fixed = (step * 8192).floor();
    final log = floorLog2(fixed);
    final p = log - 13;
    final shift = 11 - log;
    final mantissa = (shift < 0 ? fixed >> -shift : fixed << shift) & 0x7FF;
    return (8 + gain - p, mantissa);
  }

  double _stepSize(int orientation, (int, int) step) =>
      math.pow(2.0, 8 + _gain(orientation) - step.$1) * (1 + step.$2 / 2048);

  void _encodeBand(Band band, List<num> data, (int, int) step, int c) {
    final bitPlanes = _guardBits + step.$1 - 1;
    band.bitPlanes = bitPlanes;
    final delta = reversible ? 1.0 : _stepSize(band.orientation, step);
    band.stepSize = delta;
    for (final prc in band.precincts) {
      for (final cb in prc.blocks) {
        final w = cb.width, h = cb.height;
        final indices = Int32List(w * h);
        final magnitudes = reversible ? null : Float64List(w * h);
        final origin = (cb.y0 - band.y0) * band.width + cb.x0 - band.x0;
        if (reversible) {
          _copyBlock(data as Int32List, band.width, origin, indices, w, h);
        } else {
          _quantizeBlock(
            data as Float64List,
            band.width,
            origin,
            1 / delta,
            indices,
            magnitudes!,
            w,
            h,
          );
        }
        final encoded = encodeCodeBlock(
          indices: indices,
          width: w,
          height: h,
          orientation: band.orientation,
          magnitudes: magnitudes,
        );
        if (encoded.bitPlanes > bitPlanes) {
          throw J2kEncodeException(
            'coefficients exceed the $bitPlanes bit-planes band '
            '${band.orientation} allows',
          );
        }
        cb.encoded = encoded;
      }
    }
  }

  /// Chooses how many passes of each code-block to keep so the codestream
  /// meets the target size while losing the least squared error: every
  /// code-block keeps the passes whose distortion-per-byte slope is above
  /// one common threshold, found by bisection.
  void _allocateRate(List<_Component> components) {
    // At least a few bytes of packets, however small the raster, as
    // OpenJPEG does.
    final budget = math.max(
      (width * height * count / ratio).floor() - _headerLength(),
      30,
    );
    final blocks = <CodeBlock>[];
    final hulls = <List<(int, double)>>[]; // (passes, slope) on the hull
    var maxSlope = 0.0;
    for (var c = 0; c < components.length; c++) {
      for (var r = 0; r <= levels; r++) {
        for (final band in components[c].resolutions[r].bands) {
          final decomposition = r == 0 ? levels : levels - r + 1;
          final weight = math.pow(
            band.stepSize * _norm97(decomposition, band.orientation),
            2,
          );
          for (final prc in band.precincts) {
            for (final cb in prc.blocks) {
              final e = cb.encoded!;
              // Upper convex hull of (length, distortion) over the
              // truncation points; its slopes decrease.
              final points = <(int, int, double)>[(0, 0, 0.0)];
              double slope((int, int, double) a, int l, double d) =>
                  l <= a.$2 ? double.infinity : (d - a.$3) / (l - a.$2);
              for (var k = 0; k < e.passes; k++) {
                final l = e.passLengths[k];
                final d = e.passDistortions[k] * weight;
                if (d <= points.last.$3) continue;
                while (points.length >= 2 &&
                    slope(points.last, l, d) >=
                        slope(
                          points[points.length - 2],
                          points.last.$2,
                          points.last.$3,
                        )) {
                  points.removeLast();
                }
                points.add((k + 1, l, d));
              }
              final hull = <(int, double)>[
                for (var i = 1; i < points.length; i++)
                  (
                    points[i].$1,
                    slope(points[i - 1], points[i].$2, points[i].$3),
                  ),
              ];
              for (final (_, s) in hull) {
                if (s.isFinite && s > maxSlope) maxSlope = s;
              }
              blocks.add(cb);
              hulls.add(hull);
            }
          }
        }
      }
    }

    // Whether a threshold leaves the same passes as the one before it, in
    // which case its codestream length is known already.
    var length = -1;
    bool apply(double threshold) {
      var same = length >= 0;
      for (var i = 0; i < blocks.length; i++) {
        var passes = 0;
        for (final (p, s) in hulls[i]) {
          if (s < threshold) break;
          passes = p;
        }
        if (blocks[i].includedPasses != passes) {
          blocks[i].includedPasses = passes;
          same = false;
        }
      }
      return same;
    }

    apply(0);
    length = _packetsLength(components);
    if (length <= budget) return;
    var lo = 0.0, hi = maxSlope * 2 + 1;
    for (var iteration = 0; iteration < 40; iteration++) {
      final mid = (lo + hi) / 2;
      if (!apply(mid)) length = _packetsLength(components);
      if (length <= budget) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    apply(hi);
  }

  int _headerLength() {
    final bands = 3 * levels + 1;
    return 2 + // SOC
        2 +
        38 +
        3 * count + // SIZ
        2 +
        12 + // COD
        2 +
        3 +
        (reversible ? bands : 2 * bands) + // QCD
        12 + // SOT
        2 + // SOD
        2; // EOC
  }

  /// Every packet of the tile, LRCP (one layer: resolution, component,
  /// precinct): its header, and the code-blocks whose bytes follow it.
  List<(Uint8List, List<CodeBlock>)> _packets(List<_Component> components) {
    final packets = <(Uint8List, List<CodeBlock>)>[];
    for (var r = 0; r <= levels; r++) {
      for (final comp in components) {
        final res = comp.resolutions[r];
        for (var p = 0; p < res.precinctCount; p++) {
          final writer = HeaderBitWriter();
          final included = <CodeBlock>[];
          final any = res.bands.any(
            (band) =>
                band.precincts[p].blocks.any((cb) => cb.includedPasses > 0),
          );
          writer.bit(any ? 1 : 0);
          if (any) {
            for (final band in res.bands) {
              final prc = band.precincts[p];
              if (prc.blocks.isEmpty) continue;
              final inclusion = TagTree(prc.blocksWide, prc.blocksHigh)
                ..setValues([
                  for (final cb in prc.blocks) cb.includedPasses > 0 ? 0 : 1,
                ]);
              final zeroPlanes = TagTree(prc.blocksWide, prc.blocksHigh)
                ..setValues([
                  for (final cb in prc.blocks)
                    cb.includedPasses > 0
                        ? band.bitPlanes - cb.encoded!.bitPlanes
                        : 0,
                ]);
              for (var k = 0; k < prc.blocks.length; k++) {
                final cb = prc.blocks[k];
                inclusion.encode(writer, k, 1);
                if (cb.includedPasses == 0) continue;
                zeroPlanes.encode(writer, k, 1 << 30);
                final passes = cb.includedPasses;
                writePassCount(writer, passes);
                final length = cb.includedLength;
                var lblock = 3;
                while (lblock + floorLog2(passes) < length.bitLength) {
                  writer.bit(1);
                  lblock++;
                }
                writer.bit(0);
                writer.bits(length, lblock + floorLog2(passes));
                included.add(cb);
              }
            }
          }
          packets.add((writer.finish(), included));
        }
      }
    }
    return packets;
  }

  int _packetsLength(List<_Component> components) {
    var total = 0;
    for (final (header, included) in _packets(components)) {
      total += header.length;
      for (final cb in included) {
        total += cb.includedLength;
      }
    }
    return total;
  }

  Uint8List _write(List<_Component> components) {
    final packets = _packets(components);
    var dataLength = 0;
    for (final (header, included) in packets) {
      dataLength += header.length;
      for (final cb in included) {
        dataLength += cb.includedLength;
      }
    }
    final body = Uint8List(dataLength);
    var at = 0;
    for (final (header, included) in packets) {
      body.setRange(at, at + header.length, header);
      at += header.length;
      for (final cb in included) {
        final n = cb.includedLength;
        body.setRange(at, at + n, cb.encoded!.data);
        at += n;
      }
    }
    final out = BytesBuilder(copy: false);
    void u8(int v) => out.addByte(v);
    void u16(int v) => out
      ..addByte(v >> 8)
      ..addByte(v & 0xFF);
    void u32(int v) {
      u16((v >> 16) & 0xFFFF);
      u16(v & 0xFFFF);
    }

    u16(0xFF4F); // SOC
    u16(0xFF51); // SIZ
    u16(38 + 3 * count);
    u16(0); // Rsiz
    u32(width);
    u32(height);
    u32(0);
    u32(0);
    u32(width); // one tile
    u32(height);
    u32(0);
    u32(0);
    u16(count);
    for (var c = 0; c < count; c++) {
      u8(7); // 8-bit unsigned
      u8(1);
      u8(1);
    }

    u16(0xFF52); // COD
    u16(12);
    u8(0); // default precincts, no SOP/EPH
    u8(0); // LRCP
    u16(1); // one layer
    u8(0); // no component transform
    u8(levels);
    u8(_codeBlockExponent - 2);
    u8(_codeBlockExponent - 2);
    u8(0); // code-block style
    u8(reversible ? 1 : 0);

    final steps = components[0].steps;
    u16(0xFF5C); // QCD
    u16(3 + (reversible ? steps.length : 2 * steps.length));
    u8((_guardBits << 5) | (reversible ? 0 : 2));
    for (final (exponent, mantissa) in steps) {
      if (reversible) {
        u8(exponent << 3);
      } else {
        u16((exponent << 11) | mantissa);
      }
    }

    u16(0xFF90); // SOT
    u16(10);
    u16(0);
    u32(12 + 2 + dataLength);
    u8(0);
    u8(1);
    u16(0xFF93); // SOD
    out.add(body);
    u16(0xFFD9); // EOC
    return out.takeBytes();
  }
}

/// L2 norm of the 9/7 synthesis basis function of a band at
/// [decomposition] levels with [orientation]: how much a unit coefficient
/// error in it grows back in the image. Separable, so the product of the
/// horizontal and vertical 1D norms.
double _norm97(int decomposition, int orientation) {
  final horizontal = _norm1d(decomposition, (orientation & 1) != 0);
  final vertical = _norm1d(decomposition, (orientation & 2) != 0);
  return horizontal * vertical;
}

final _norms1d = <int, double>{};

double _norm1d(int levels, bool high) =>
    _norms1d.putIfAbsent(levels * 2 + (high ? 1 : 0), () {
      // An impulse at the middle of a band, synthesized back up [levels]
      // levels of a 1-row signal.
      const size = 4096;
      final n = size >> levels;
      var low = Float64List(n);
      var hi = Float64List(n);
      (high ? hi : low)[n ~/ 2] = 1;
      for (var l = levels; l >= 1; l--) {
        final out = inverse97(
          SubBands(low, hi, Float64List(0), Float64List(0)),
          0,
          0,
          size >> (l - 1),
          1,
        );
        low = out;
        hi = Float64List(size >> (l - 1));
      }
      var sum = 0.0;
      for (final v in low) {
        sum += v * v;
      }
      return math.sqrt(sum);
    });

/// Copies a code-block's `w x h` coefficients out of its band.
void _copyBlock(
  Int32List band,
  int bandWidth,
  int origin,
  Int32List out,
  int w,
  int h,
) {
  for (var j = 0; j < h; j++) {
    out.setRange(j * w, j * w + w, band, origin + j * bandWidth);
  }
}

/// Quantizes a code-block's coefficients out of its band: dead-zone
/// indices, and the exact magnitudes they came from, in steps.
void _quantizeBlock(
  Float64List band,
  int bandWidth,
  int origin,
  double inverseStep,
  Int32List indices,
  Float64List magnitudes,
  int w,
  int h,
) {
  for (var j = 0; j < h; j++) {
    final row = origin + j * bandWidth;
    for (var i = 0; i < w; i++) {
      final v = band[row + i] * inverseStep;
      final m = v < 0 ? -v : v;
      magnitudes[j * w + i] = m;
      final q = m.toInt();
      indices[j * w + i] = v < 0 ? -q : q;
    }
  }
}
