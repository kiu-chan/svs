// A JPEG2000 Part 1 (ISO/IEC 15444-1) codestream decoder: every progression
// order and POC, tiles and tile-parts, precincts, all code-block styles,
// SOP/EPH, packed packet headers (PPM/PPT), ROI (max-shift), both wavelet
// transforms and both component transforms, and decoding at reduced
// resolution. Decodes raw codestreams (starting with SOC, as TIFF stores
// them), not the box-structured JP2 file format.
import 'dart:math' as math;
import 'dart:typed_data';

import 'dwt.dart';
import 'j2k_structure.dart';
import 'tier1.dart';
import 'tier2.dart';

/// A decoded image: [numComponents] 8-bit samples per pixel, interleaved,
/// row-major, no padding.
class J2kImage {
  final int width;
  final int height;
  final int numComponents;
  final Uint8List pixels;

  const J2kImage({
    required this.width,
    required this.height,
    required this.numComponents,
    required this.pixels,
  });
}

class J2kDecodeException implements Exception {
  final String message;

  const J2kDecodeException(this.message);

  @override
  String toString() => 'J2kDecodeException: $message';
}

/// Decodes a raw JPEG2000 codestream.
///
/// [reducedResolutionFactor] discards that many of the highest resolution
/// levels, decoding a `ceil(width / 2^f) x ceil(height / 2^f)` image — much
/// less work when only a preview is needed. Throws [J2kDecodeException] if
/// the codestream is malformed or has fewer decomposition levels than that.
///
/// Samples of other bit depths are scaled to 8 bits, signed ones offset to
/// unsigned, and subsampled components repeated to full size.
J2kImage decodeJ2k(Uint8List bytes, {int reducedResolutionFactor = 0}) {
  try {
    return _Decoder(bytes, reducedResolutionFactor).decode();
  } on J2kDecodeException {
    rethrow;
  } on RangeError catch (e) {
    throw J2kDecodeException('truncated or corrupt codestream ($e)');
  } on StateError catch (e) {
    throw J2kDecodeException('corrupt codestream (${e.message})');
  }
}

const _soc = 0xFF4F;
const _siz = 0xFF51;
const _cod = 0xFF52;
const _coc = 0xFF53;
const _qcd = 0xFF5C;
const _qcc = 0xFF5D;
const _rgn = 0xFF5E;
const _poc = 0xFF5F;
const _ppm = 0xFF60;
const _ppt = 0xFF61;
const _cap = 0xFF50;
const _sot = 0xFF90;
const _sod = 0xFF93;
const _eoc = 0xFFD9;

const _lrcp = 0;
const _rlcp = 1;
const _rpcl = 2;
const _pcrl = 3;
const _cprl = 4;

class _Component {
  final int precision;
  final bool signed;
  final int dx;
  final int dy;

  const _Component(this.precision, this.signed, this.dx, this.dy);
}

/// SPcod/SPcoc: what COD and COC can set per component.
class _Style {
  final int levels;
  final int xcb;
  final int ycb;
  final int cbStyle;
  final bool reversible;
  final List<(int, int)> precincts;

  const _Style(
    this.levels,
    this.xcb,
    this.ycb,
    this.cbStyle,
    this.reversible,
    this.precincts,
  );
}

class _Cod {
  final int progression;
  final int layers;
  final bool mct;
  final bool sop;
  final bool eph;
  final _Style style;

  const _Cod(
    this.progression,
    this.layers,
    this.mct,
    this.sop,
    this.eph,
    this.style,
  );
}

class _Quant {
  final int style;
  final int guardBits;
  final List<int> exponents;
  final List<int> mantissas;

  const _Quant(this.style, this.guardBits, this.exponents, this.mantissas);
}

class _Poc {
  final int resStart;
  final int compStart;
  final int layerEnd;
  final int resEnd;
  final int compEnd;
  final int order;

  const _Poc(
    this.resStart,
    this.compStart,
    this.layerEnd,
    this.resEnd,
    this.compEnd,
    this.order,
  );
}

/// Coding parameters a header (main, or a tile's first tile-part) sets.
class _Params {
  _Cod? cod;
  final coc = <int, _Style>{};
  _Quant? qcd;
  final qcc = <int, _Quant>{};
  final rgn = <int, int>{};
  final poc = <_Poc>[];
}

class _Tile {
  final _Params params = _Params();
  final data = <Uint8List>[];
  final packedHeaders = <Uint8List>[];
  var tileParts = 0;
}

class _TileComponent {
  final _Component component;
  final _Style style;
  final List<Resolution> resolutions;
  final int roiShift;

  const _TileComponent(
    this.component,
    this.style,
    this.resolutions,
    this.roiShift,
  );
}

class _Decoder {
  final Uint8List _b;
  final int _reduce;

  late int _xsiz, _ysiz, _xo, _yo, _xt, _yt, _xto, _yto;
  late List<_Component> _components;
  final _main = _Params();

  // The image being assembled, and where each component's samples go in
  // it: straight into [_out], or into a plane first (see decode).
  late final Uint8List _out;
  late final int _outWidth;
  late final int _outComponents;
  final _planes = <Int32List?>[];
  final _planeX0 = <int>[];
  final _planeY0 = <int>[];
  final _planeW = <int>[];
  final _planeH = <int>[];
  final _ppmSegments = <(int, Uint8List)>[];
  final _tiles = <int, _Tile>{};

  _Decoder(this._b, this._reduce);

  int _u8(int p) => _b[p];
  int _u16(int p) => (_b[p] << 8) | _b[p + 1];
  int _u32(int p) =>
      (_b[p] << 24 | _b[p + 1] << 16 | _b[p + 2] << 8 | _b[p + 3]) & 0xFFFFFFFF;

  Never _fail(String message) => throw J2kDecodeException(message);

  J2kImage decode() {
    if (_b.length < 4 || _u16(0) != _soc) {
      _fail('not a JPEG2000 codestream (no SOC marker)');
    }
    var p = 2;
    if (_u16(p) != _siz) _fail('SIZ marker missing after SOC');
    while (true) {
      if (p + 4 > _b.length) _fail('codestream ends inside its main header');
      final marker = _u16(p);
      if (marker == _sot) break;
      if (marker >> 8 != 0xFF) _fail('expected a marker at offset $p');
      final length = _u16(p + 2);
      final start = p + 4;
      final end = p + 2 + length;
      if (end > _b.length) _fail('marker segment runs past the end');
      switch (marker) {
        case _siz:
          _readSiz(start);
        case _cap:
          _fail('HTJ2K (Part 15) codestreams are not supported');
        case _ppm:
          _ppmSegments.add((
            _u8(start),
            Uint8List.sublistView(_b, start + 1, end),
          ));
        default:
          _readParam(_main, marker, start, end);
      }
      p = end;
    }
    if (_main.cod == null) _fail('COD marker missing from the main header');
    if (_main.qcd == null) _fail('QCD marker missing from the main header');
    _readTileParts(p);

    final numComponents = _components.length;
    final f = _reduce;
    final imageX0 = ceilDivPow2(_xo, f);
    final imageY0 = ceilDivPow2(_yo, f);
    final width = ceilDivPow2(_xsiz, f) - imageX0;
    final height = ceilDivPow2(_ysiz, f) - imageY0;

    // Each component's samples at the output resolution, on its own grid.
    // One that is neither subsampled nor deeper than 8 bits goes straight
    // into the output as its tile is decoded; the rest go through a plane,
    // to be upsampled and scaled once every tile is in.
    final out = Uint8List(width * height * numComponents);
    _out = out;
    _outWidth = width;
    _outComponents = numComponents;
    for (final c in _components) {
      final x0 = ceilDivPow2(ceilDiv(_xo, c.dx), f);
      final y0 = ceilDivPow2(ceilDiv(_yo, c.dy), f);
      final w = ceilDivPow2(ceilDiv(_xsiz, c.dx), f) - x0;
      final h = ceilDivPow2(ceilDiv(_ysiz, c.dy), f) - y0;
      _planeX0.add(x0);
      _planeY0.add(y0);
      _planeW.add(w);
      _planeH.add(h);
      final direct = c.dx == 1 && c.dy == 1 && c.precision == 8 && !c.signed;
      _planes.add(direct ? null : Int32List(w * h));
    }
    final tileKeys = _tiles.keys.toList()..sort();
    for (final t in tileKeys) {
      _decodeTile(t, _tiles[t]!);
    }
    // Upsample and scale whatever went through a plane.
    for (var c = 0; c < numComponents; c++) {
      final plane = _planes[c];
      if (plane == null) continue;
      final comp = _components[c];
      final pw = _planeW[c];
      final ph = _planeH[c];
      if (pw == 0 || ph == 0) continue;
      final offset = comp.signed ? 1 << (comp.precision - 1) : 0;
      final shift = comp.precision - 8;
      for (var y = 0; y < height; y++) {
        var sy = y ~/ comp.dy;
        if (sy >= ph) sy = ph - 1;
        for (var x = 0; x < width; x++) {
          var sx = x ~/ comp.dx;
          if (sx >= pw) sx = pw - 1;
          var v = plane[sy * pw + sx] + offset;
          v = shift > 0 ? v >> shift : v << -shift;
          out[(y * width + x) * numComponents + c] = v < 0
              ? 0
              : (v > 255 ? 255 : v);
        }
      }
    }
    return J2kImage(
      width: width,
      height: height,
      numComponents: numComponents,
      pixels: out,
    );
  }

  void _readSiz(int p) {
    _xsiz = _u32(p + 2);
    _ysiz = _u32(p + 6);
    _xo = _u32(p + 10);
    _yo = _u32(p + 14);
    _xt = _u32(p + 18);
    _yt = _u32(p + 22);
    _xto = _u32(p + 26);
    _yto = _u32(p + 30);
    final count = _u16(p + 34);
    if (count == 0 || count > 16384) _fail('invalid component count $count');
    if (_xt == 0 || _yt == 0 || _xsiz <= _xo || _ysiz <= _yo) {
      _fail('invalid image or tile size');
    }
    _components = [
      for (var i = 0; i < count; i++)
        _Component(
          (_u8(p + 36 + 3 * i) & 0x7F) + 1,
          (_u8(p + 36 + 3 * i) & 0x80) != 0,
          _u8(p + 37 + 3 * i),
          _u8(p + 38 + 3 * i),
        ),
    ];
    for (final c in _components) {
      if (c.dx == 0 || c.dy == 0) _fail('invalid component subsampling');
      if (c.precision > 31) _fail('unsupported bit depth ${c.precision}');
    }
  }

  int get _compIndexSize => _components.length < 257 ? 1 : 2;

  int _readCompIndex(int p) => _compIndexSize == 1 ? _u8(p) : _u16(p);

  _Style _readStyle(int p, bool userPrecincts) {
    final levels = _u8(p);
    if (levels > 32) _fail('invalid decomposition level count $levels');
    final xcb = (_u8(p + 1) & 0xF) + 2;
    final ycb = (_u8(p + 2) & 0xF) + 2;
    if (xcb > 10 || ycb > 10 || xcb + ycb > 12) {
      _fail('invalid code-block size');
    }
    return _Style(levels, xcb, ycb, _u8(p + 3), _u8(p + 4) == 1, [
      for (var r = 0; r <= levels; r++)
        userPrecincts ? (_u8(p + 5 + r) & 0xF, _u8(p + 5 + r) >> 4) : (15, 15),
    ]);
  }

  _Quant _readQuant(int p, int end) {
    final s = _u8(p);
    final style = s & 0x1F;
    final exps = <int>[];
    final mants = <int>[];
    if (style == 0) {
      for (var q = p + 1; q < end; q++) {
        exps.add(_u8(q) >> 3);
        mants.add(0);
      }
    } else {
      for (var q = p + 1; q + 1 < end; q += 2) {
        final v = _u16(q);
        exps.add(v >> 11);
        mants.add(v & 0x7FF);
      }
    }
    if (exps.isEmpty) _fail('empty quantization marker');
    return _Quant(style, s >> 5, exps, mants);
  }

  void _readParam(_Params params, int marker, int p, int end) {
    switch (marker) {
      case _cod:
        final scod = _u8(p);
        params.cod = _Cod(
          _u8(p + 1),
          _u16(p + 2),
          _u8(p + 4) != 0,
          (scod & 2) != 0,
          (scod & 4) != 0,
          _readStyle(p + 5, (scod & 1) != 0),
        );
      case _coc:
        final c = _readCompIndex(p);
        final n = _compIndexSize;
        params.coc[c] = _readStyle(p + n + 1, (_u8(p + n) & 1) != 0);
      case _qcd:
        params.qcd = _readQuant(p, end);
      case _qcc:
        final c = _readCompIndex(p);
        params.qcc[c] = _readQuant(p + _compIndexSize, end);
      case _rgn:
        final c = _readCompIndex(p);
        final n = _compIndexSize;
        if (_u8(p + n) == 0) params.rgn[c] = _u8(p + n + 1);
      case _poc:
        final n = _compIndexSize;
        final entry = 5 + 2 * n;
        for (var q = p; q + entry <= end; q += entry) {
          final ce = _readCompIndex(q + 4 + n);
          params.poc.add(
            _Poc(
              _u8(q),
              _readCompIndex(q + 1),
              _u16(q + 1 + n),
              _u8(q + 3 + n),
              ce == 0 ? 256 : ce,
              _u8(q + 4 + 2 * n),
            ),
          );
        }
      default:
        // TLM, PLM, PLT, CRG, COM and unknown segments carry nothing the
        // decode needs.
        break;
    }
  }

  void _readTileParts(int p) {
    final tilesX = ceilDiv(_xsiz - _xto, _xt);
    final tilesY = ceilDiv(_ysiz - _yto, _yt);
    final ppmStream = _ppmSegments.isEmpty ? null : _concatPpm();
    var ppmPos = 0;
    while (p + 2 <= _b.length) {
      final marker = _u16(p);
      if (marker == _eoc) break;
      if (marker != _sot) break; // Trailing garbage: stop, keep what we have.
      if (p + 12 > _b.length) break;
      final index = _u16(p + 4);
      final psot = _u32(p + 6);
      if (index >= tilesX * tilesY) _fail('tile index $index out of range');
      final tile = _tiles.putIfAbsent(index, _Tile.new);
      final firstPart = tile.tileParts == 0;
      tile.tileParts++;
      final partEnd = psot == 0 ? _b.length : math.min(p + psot, _b.length);
      var q = p + 12;
      while (q + 2 <= partEnd && _u16(q) != _sod) {
        final m = _u16(q);
        final length = _u16(q + 2);
        final end = q + 2 + length;
        if (end > partEnd) _fail('tile-part header runs past its tile-part');
        if (m == _ppt) {
          tile.packedHeaders.add(Uint8List.sublistView(_b, q + 5, end));
        } else if (firstPart || m == _poc) {
          _readParam(tile.params, m, q + 4, end);
        }
        q = end;
      }
      q += 2;
      var dataEnd = partEnd;
      if (psot == 0 && dataEnd - 2 >= q && _u16(dataEnd - 2) == _eoc) {
        dataEnd -= 2;
      }
      if (q < dataEnd) tile.data.add(Uint8List.sublistView(_b, q, dataEnd));
      if (ppmStream != null && ppmPos + 4 <= ppmStream.length) {
        final n =
            (ppmStream[ppmPos] << 24 |
                ppmStream[ppmPos + 1] << 16 |
                ppmStream[ppmPos + 2] << 8 |
                ppmStream[ppmPos + 3]) &
            0xFFFFFFFF;
        ppmPos += 4;
        final end = math.min(ppmPos + n, ppmStream.length);
        tile.packedHeaders.add(Uint8List.sublistView(ppmStream, ppmPos, end));
        ppmPos = end;
      }
      if (psot == 0) break;
      p = partEnd;
    }
  }

  Uint8List _concatPpm() {
    _ppmSegments.sort((a, b) => a.$1.compareTo(b.$1));
    return _concat([for (final (_, d) in _ppmSegments) d]);
  }

  static Uint8List _concat(List<Uint8List> parts) {
    if (parts.length == 1) return parts.single;
    var total = 0;
    for (final part in parts) {
      total += part.length;
    }
    final out = Uint8List(total);
    var o = 0;
    for (final part in parts) {
      out.setRange(o, o + part.length, part);
      o += part.length;
    }
    return out;
  }

  /// Decodes tile [t] at the output resolution into the image.
  void _decodeTile(int t, _Tile tile) {
    final tilesX = ceilDiv(_xsiz - _xto, _xt);
    final p = t % tilesX;
    final q = t ~/ tilesX;
    final tx0 = math.max(_xto + p * _xt, _xo);
    final ty0 = math.max(_yto + q * _yt, _yo);
    final tx1 = math.min(_xto + (p + 1) * _xt, _xsiz);
    final ty1 = math.min(_yto + (q + 1) * _yt, _ysiz);

    final tp = tile.params;
    final cod = tp.cod ?? _main.cod!;
    final comps = <_TileComponent>[];
    for (var c = 0; c < _components.length; c++) {
      final comp = _components[c];
      final style =
          tp.coc[c] ??
          (tp.cod != null ? tp.cod!.style : (_main.coc[c] ?? cod.style));
      final quant = tp.qcc[c] ?? tp.qcd ?? _main.qcc[c] ?? _main.qcd!;
      final roi = tp.rgn[c] ?? _main.rgn[c] ?? 0;
      if (_reduce > style.levels) {
        _fail(
          'cannot discard $_reduce resolution levels: component $c has only '
          '${style.levels} decomposition levels',
        );
      }
      final resolutions = buildResolutions(
        x0: ceilDiv(tx0, comp.dx),
        y0: ceilDiv(ty0, comp.dy),
        x1: ceilDiv(tx1, comp.dx),
        y1: ceilDiv(ty1, comp.dy),
        levels: style.levels,
        xcb: style.xcb,
        ycb: style.ycb,
        precinctExponents: style.precincts,
      );
      for (var r = 0; r < resolutions.length; r++) {
        for (final band in resolutions[r].bands) {
          _quantize(band, quant, style, comp, r, roi);
        }
      }
      comps.add(_TileComponent(comp, style, resolutions, roi));
    }

    _readPackets(tile, cod, comps, tx0, ty0, tx1, ty1);

    // Tier-1, dequantization and the inverse wavelet transform, per
    // component, up to the output resolution.
    final floats = <Float64List?>[];
    final ints = <Int32List?>[];
    final rects = <(int, int, int, int)>[];
    for (final tc in comps) {
      final target = tc.style.levels - _reduce;
      final reversible = tc.style.reversible;
      Int32List? intLevel;
      Float64List? floatLevel;
      for (var r = 0; r <= target; r++) {
        final res = tc.resolutions[r];
        final w = res.width, h = res.height;
        // A level's sub-bands are decoded straight into it, each on every
        // other sample from its own corner, with resolution 0's low-pass
        // band — the level below, already reconstructed — interleaved in.
        if (reversible) {
          final level = Int32List(w * h);
          if (r > 0) {
            final (ox, oy) = bandOrigin(orientLL, res.x0, res.y0);
            final below = tc.resolutions[r - 1];
            interleaveInts(
              level,
              w,
              intLevel!,
              below.width,
              below.height,
              ox,
              oy,
            );
          }
          for (final band in res.bands) {
            final (ox, oy) = r == 0
                ? (0, 0)
                : bandOrigin(band.orientation, res.x0, res.y0);
            _decodeBand(band, tc, level, null, w, ox, oy, r == 0 ? 1 : 2, 1);
          }
          if (r > 0) inverse53InPlace(level, res.x0, res.y0, res.x1, res.y1);
          intLevel = level;
        } else {
          final level = Float64List(w * h);
          if (r > 0) {
            final (ox, oy) = bandOrigin(orientLL, res.x0, res.y0);
            final below = tc.resolutions[r - 1];
            interleaveFloats(
              level,
              w,
              floatLevel!,
              below.width,
              below.height,
              ox,
              oy,
              gain97(orientLL, w, h),
            );
          }
          for (final band in res.bands) {
            final (ox, oy) = r == 0
                ? (0, 0)
                : bandOrigin(band.orientation, res.x0, res.y0);
            _decodeBand(
              band,
              tc,
              null,
              level,
              w,
              ox,
              oy,
              r == 0 ? 1 : 2,
              r == 0 ? 1 : gain97(band.orientation, w, h),
            );
          }
          if (r > 0) inverse97InPlace(level, res.x0, res.y0, res.x1, res.y1);
          floatLevel = level;
        }
      }
      ints.add(intLevel);
      floats.add(floatLevel);
      final res = tc.resolutions[target];
      rects.add((res.x0, res.y0, res.width, res.height));
    }
    var first = 0;
    if (cod.mct && comps.length >= 3) {
      if (_mctToOutput(comps, ints, floats, rects)) {
        first = 3;
      } else {
        _inverseMct(comps, ints, floats, rects);
      }
    }
    for (var c = first; c < comps.length; c++) {
      _emit(c, rects[c], ints[c], floats[c]);
    }
  }

  /// Writes one component's samples into the image: level-shifted and
  /// clamped to 8 bits straight into the output, or into its plane for a
  /// second pass to upsample and scale.
  void _emit(
    int c,
    (int, int, int, int) rect,
    Int32List? ints,
    Float64List? floats,
  ) {
    final (x0, y0, w, h) = rect;
    final (start, from, cols, rows) = _target(c, x0, y0, w, h);
    if (cols <= 0 || rows <= 0) return;
    final plane = _planes[c];
    if (plane == null) {
      final stride = _outWidth * _outComponents;
      if (ints != null) {
        _writeInts(
          _out,
          start,
          stride,
          _outComponents,
          ints,
          from,
          w,
          cols,
          rows,
        );
      } else {
        _writeFloats(
          _out,
          start,
          stride,
          _outComponents,
          floats!,
          from,
          w,
          cols,
          rows,
        );
      }
      return;
    }
    final data = _levelShift(_components[c], ints, floats);
    final pw = _planeW[c];
    final ox = x0 - _planeX0[c];
    final oy = y0 - _planeY0[c];
    final i0 = from % w;
    final j0 = from ~/ w;
    for (var j = 0; j < rows; j++) {
      final row = oy + j0 + j;
      plane.setRange(
        row * pw + ox + i0,
        row * pw + ox + i0 + cols,
        data,
        from + j * w,
      );
    }
  }

  /// Where a component's samples land: the index in the output of the
  /// first one kept, the index in the samples it comes from, and how many
  /// columns and rows are kept (the rest fall outside the image).
  (int, int, int, int) _target(int c, int x0, int y0, int w, int h) {
    final ox = x0 - _planeX0[c];
    final oy = y0 - _planeY0[c];
    final i0 = math.max(0, -ox);
    final i1 = math.min(w, _planeW[c] - ox);
    final j0 = math.max(0, -oy);
    final j1 = math.min(h, _planeH[c] - oy);
    final start = ((oy + j0) * _outWidth + ox + i0) * _outComponents + c;
    return (start, j0 * w + i0, i1 - i0, j1 - j0);
  }

  /// Applies the component transform straight into the output where
  /// components 0 to 2 all go there whole; returns whether it did.
  bool _mctToOutput(
    List<_TileComponent> comps,
    List<Int32List?> ints,
    List<Float64List?> floats,
    List<(int, int, int, int)> rects,
  ) {
    for (var c = 0; c < 3; c++) {
      if (_planes[c] != null) return false;
      if (rects[c] != rects[0]) return false;
      if (comps[c].style.reversible != comps[0].style.reversible) return false;
    }
    final (x0, y0, w, h) = rects[0];
    final (start, from, cols, rows) = _target(0, x0, y0, w, h);
    if (cols <= 0 || rows <= 0) return true;
    final stride = _outWidth * _outComponents;
    if (comps[0].style.reversible) {
      _writeRct(
        _out,
        start,
        stride,
        _outComponents,
        ints[0]!,
        ints[1]!,
        ints[2]!,
        from,
        w,
        cols,
        rows,
      );
    } else {
      _writeIct(
        _out,
        start,
        stride,
        _outComponents,
        floats[0]!,
        floats[1]!,
        floats[2]!,
        from,
        w,
        cols,
        rows,
      );
    }
    return true;
  }

  void _quantize(
    Band band,
    _Quant quant,
    _Style style,
    _Component comp,
    int r,
    int roi,
  ) {
    final index = r == 0 ? 0 : 3 * (r - 1) + band.orientation;
    int exponent, mantissa;
    if (quant.style == 1) {
      // Scalar derived (E-5): only LL's step is signalled.
      final levelsBelow = r == 0 ? style.levels : style.levels - r + 1;
      exponent = quant.exponents[0] - style.levels + levelsBelow;
      mantissa = quant.mantissas[0];
    } else {
      final i = index < quant.exponents.length
          ? index
          : quant.exponents.length - 1;
      exponent = quant.exponents[i];
      mantissa = quant.mantissas[i];
    }
    band.bitPlanes = quant.guardBits + exponent - 1 + roi;
    final gain = band.orientation == orientLL
        ? 0
        : (band.orientation == orientHH ? 2 : 1);
    band.stepSize =
        math.pow(2.0, comp.precision + gain - exponent) *
        (1 + mantissa / 2048.0);
  }

  /// Reads every packet of the tile, filling its code-blocks.
  void _readPackets(
    _Tile tile,
    _Cod cod,
    List<_TileComponent> comps,
    int tx0,
    int ty0,
    int tx1,
    int ty1,
  ) {
    final data = _concat(tile.data);
    final packed = tile.packedHeaders.isEmpty
        ? null
        : HeaderBitReader(
            _concat(tile.packedHeaders),
            0,
            tile.packedHeaders.fold(0, (n, b) => n + b.length),
          );
    var pos = 0;
    final pocs = tile.params.poc.isNotEmpty ? tile.params.poc : _main.poc;
    final target = [for (final tc in comps) tc.style.levels - _reduce];

    try {
      for (final (layer, r, c, precinct) in _packetOrder(
        cod,
        comps,
        pocs,
        tx0,
        ty0,
      )) {
        final res = comps[c].resolutions[r];
        if (cod.sop &&
            pos + 6 <= data.length &&
            data[pos] == 0xFF &&
            data[pos + 1] == 0x91) {
          pos += 6;
        }
        final reader = packed ?? HeaderBitReader(data, pos, data.length);
        final contributions = <(CodeBlock, DecodingSegment, int)>[];
        if (reader.bit() == 1) {
          for (final band in res.bands) {
            final prc = band.precincts[precinct];
            for (var k = 0; k < prc.blocks.length; k++) {
              final cb = prc.blocks[k];
              final bool included;
              if (!cb.included) {
                included = prc.inclusion.decode(reader, k, layer + 1);
              } else {
                included = reader.bit() == 1;
              }
              if (!included) continue;
              if (!cb.included) {
                var i = 1;
                while (!prc.zeroBitPlanes.decode(reader, k, i)) {
                  i++;
                }
                cb.zeroBitPlanes = i - 1;
                cb.included = true;
              }
              var remaining = readPassCount(reader);
              cb.passes += remaining;
              while (reader.bit() == 1) {
                cb.lblock++;
              }
              final cbStyle = comps[c].style.cbStyle;
              if (cb.segments.isEmpty ||
                  cb.segments.last.passes == cb.segments.last.maxPasses) {
                cb.segments.add(DecodingSegment(_maxPasses(cb, cbStyle)));
              }
              while (true) {
                final seg = cb.segments.last;
                final take = math.min(seg.maxPasses - seg.passes, remaining);
                final length = reader.bits(cb.lblock + floorLog2(take));
                seg.passes += take;
                contributions.add((cb, seg, length));
                remaining -= take;
                if (remaining <= 0) break;
                cb.segments.add(DecodingSegment(_maxPasses(cb, cbStyle)));
              }
            }
          }
        }
        reader.align();
        if (cod.eph) reader.skipEph();
        if (packed == null) pos = reader.position;
        final keep = r <= target[c];
        for (final (cb, seg, length) in contributions) {
          final n = math.min(length, data.length - pos);
          if (keep && n > 0) {
            cb.chunks.add(Uint8List.sublistView(data, pos, pos + n));
          }
          seg.length += n;
          pos += n;
        }
        if (pos >= data.length && packed == null) break;
      }
    } catch (e) {
      // A truncated tile: decode whatever arrived before the cut.
      if (!isEndOfHeader(e)) rethrow;
    }
  }

  /// Passes the next codeword segment of [cb] may hold (B.10.7.1).
  static int _maxPasses(CodeBlock cb, int cbStyle) {
    if ((cbStyle & cbStyleTermAll) != 0) return 1;
    if ((cbStyle & cbStyleBypass) != 0) {
      if (cb.segments.isEmpty) return 10;
      final previous = cb.segments.last.maxPasses;
      return previous == 1 || previous == 10 ? 2 : 1;
    }
    return 1 << 30;
  }

  /// Every packet of a tile as `(layer, resolution, component, precinct)`,
  /// in codestream order (B.12), honouring any progression order changes.
  List<(int, int, int, int)> _packetOrder(
    _Cod cod,
    List<_TileComponent> comps,
    List<_Poc> pocs,
    int tx0,
    int ty0,
  ) {
    final maxRes = comps.fold(0, (m, tc) => math.max(m, tc.resolutions.length));
    final volumes = pocs.isEmpty
        ? [_Poc(0, 0, cod.layers, maxRes, comps.length, cod.progression)]
        : pocs;
    // Per (resolution, component), the (layer, precinct) pairs emitted.
    final emitted = [for (var i = 0; i < maxRes * comps.length; i++) <int>{}];
    final order = <(int, int, int, int)>[];

    // Each precinct's position on the reference grid (B.12.1.3): its
    // origin, or the tile's for a precinct straddling the tile's edge.
    (int, int) position(int c, int r, int p) {
      final tc = comps[c];
      final res = tc.resolutions[r];
      final levelNo = tc.resolutions.length - 1 - r;
      final i = p % res.precinctsWide;
      final j = p ~/ res.precinctsWide;
      final px = ((res.x0 >> res.ppx) + i) << res.ppx;
      final py = ((res.y0 >> res.ppy) + j) << res.ppy;
      return (
        math.max(py * tc.component.dy << levelNo, ty0),
        math.max(px * tc.component.dx << levelNo, tx0),
      );
    }

    for (final v in volumes) {
      final layerEnd = math.min(v.layerEnd, cod.layers);
      final compEnd = math.min(v.compEnd, comps.length);
      void emit(int l, int r, int c, int p) {
        final key = l * comps[c].resolutions[r].precinctCount + p;
        if (emitted[r * comps.length + c].add(key)) order.add((l, r, c, p));
      }

      bool hasRes(int c, int r) => r < comps[c].resolutions.length;
      int precincts(int c, int r) => comps[c].resolutions[r].precinctCount;

      switch (v.order) {
        case _lrcp:
          for (var l = 0; l < layerEnd; l++) {
            for (var r = v.resStart; r < v.resEnd; r++) {
              for (var c = v.compStart; c < compEnd; c++) {
                if (!hasRes(c, r)) continue;
                for (var p = 0; p < precincts(c, r); p++) {
                  emit(l, r, c, p);
                }
              }
            }
          }
        case _rlcp:
          for (var r = v.resStart; r < v.resEnd; r++) {
            for (var l = 0; l < layerEnd; l++) {
              for (var c = v.compStart; c < compEnd; c++) {
                if (!hasRes(c, r)) continue;
                for (var p = 0; p < precincts(c, r); p++) {
                  emit(l, r, c, p);
                }
              }
            }
          }
        case _rpcl || _pcrl || _cprl:
          final entries = <(int, int, int, int, int)>[]; // y, x, c, r, p
          for (var c = v.compStart; c < compEnd; c++) {
            for (var r = v.resStart; r < v.resEnd; r++) {
              if (!hasRes(c, r)) continue;
              for (var p = 0; p < precincts(c, r); p++) {
                final (y, x) = position(c, r, p);
                entries.add((y, x, c, r, p));
              }
            }
          }
          int compare(
            (int, int, int, int, int) a,
            (int, int, int, int, int) b,
          ) {
            final keysA = switch (v.order) {
              _rpcl => [a.$4, a.$1, a.$2, a.$3],
              _pcrl => [a.$1, a.$2, a.$3, a.$4],
              _ => [a.$3, a.$1, a.$2, a.$4],
            };
            final keysB = switch (v.order) {
              _rpcl => [b.$4, b.$1, b.$2, b.$3],
              _pcrl => [b.$1, b.$2, b.$3, b.$4],
              _ => [b.$3, b.$1, b.$2, b.$4],
            };
            for (var k = 0; k < 4; k++) {
              final d = keysA[k].compareTo(keysB[k]);
              if (d != 0) return d;
            }
            return 0;
          }

          entries.sort(compare);
          for (final (_, _, c, r, p) in entries) {
            for (var l = 0; l < layerEnd; l++) {
              emit(l, r, c, p);
            }
          }
        default:
          _fail('unknown progression order ${v.order}');
      }
    }
    return order;
  }

  /// Decodes a sub-band's code-blocks into the resolution level they
  /// belong to, dequantized: [ints] for the reversible transform, [floats]
  /// otherwise, [levelWidth] wide, from column [ox] and row [oy], every
  /// [step] samples, scaled by [gain] on top of the band's step size.
  void _decodeBand(
    Band band,
    _TileComponent tc,
    Int32List? ints,
    Float64List? floats,
    int levelWidth,
    int ox,
    int oy,
    int step,
    double gain,
  ) {
    final cbStyle = tc.style.cbStyle;
    final roi = tc.roiShift;
    final scale = band.stepSize / 2 * gain;
    Int32List buffer = Int32List(0);
    for (final prc in band.precincts) {
      for (final cb in prc.blocks) {
        if (cb.passes == 0 || cb.chunks.isEmpty) continue;
        final cw = cb.width;
        final ch = cb.height;
        if (buffer.length < cw * ch) buffer = Int32List(cw * ch);
        final (data, segments) = cb.collectData();
        decodeCodeBlock(
          out: buffer,
          width: cw,
          height: ch,
          orientation: band.orientation,
          cbStyle: cbStyle,
          bitPlanes: band.bitPlanes,
          zeroBitPlanes: cb.zeroBitPlanes,
          passes: cb.passes,
          data: data,
          segments: segments,
        );
        final x = ox + step * (cb.x0 - band.x0);
        final y = oy + step * (cb.y0 - band.y0);
        if (roi > 0) _unshiftRoi(buffer, cw * ch, roi);
        if (ints != null) {
          _placeInts(buffer, cw, ch, ints, levelWidth, x, y, step);
        } else {
          _placeFloats(buffer, cw, ch, floats!, levelWidth, x, y, step, scale);
        }
      }
    }
  }

  void _inverseMct(
    List<_TileComponent> comps,
    List<Int32List?> ints,
    List<Float64List?> floats,
    List<(int, int, int, int)> rects,
  ) {
    for (var c = 1; c < 3; c++) {
      if (rects[c].$3 != rects[0].$3 || rects[c].$4 != rects[0].$4) return;
      if (comps[c].style.reversible != comps[0].style.reversible) return;
    }
    if (comps[0].style.reversible) {
      final y = ints[0]!, u = ints[1]!, v = ints[2]!;
      for (var i = 0; i < y.length; i++) {
        final g = y[i] - _shiftRight2(u[i] + v[i]);
        final r = v[i] + g;
        final b = u[i] + g;
        y[i] = r;
        u[i] = g;
        v[i] = b;
      }
    } else {
      _ict(floats[0]!, floats[1]!, floats[2]!);
    }
  }

  /// Rounds, level-shifts and clamps a component's samples to its range.
  Int32List _levelShift(_Component comp, Int32List? ints, Float64List? floats) {
    final shift = comp.signed ? 0 : 1 << (comp.precision - 1);
    final min = comp.signed ? -(1 << (comp.precision - 1)) : 0;
    final max = comp.signed
        ? (1 << (comp.precision - 1)) - 1
        : (1 << comp.precision) - 1;
    if (ints != null) {
      _shiftInts(ints, shift, min, max);
      return ints;
    }
    final out = Int32List(floats!.length);
    _shiftFloats(floats, out, shift, min, max);
    return out;
  }
}

void _ict(Float64List y, Float64List cb, Float64List cr) {
  final n = y.length;
  for (var i = 0; i < n; i++) {
    final yy = y[i], u = cb[i], v = cr[i];
    y[i] = yy + 1.402 * v;
    cb[i] = yy - 0.34413 * u - 0.71414 * v;
    cr[i] = yy + 1.772 * u;
  }
}

// Hot loops live in top-level functions over non-null typed lists: inside a
// larger method, or behind a nullable variable, the AOT compiler generates
// several times slower code for them.

void _unshiftRoi(Int32List buffer, int n, int roi) {
  final threshold = 1 << (roi + 1);
  for (var i = 0; i < n; i++) {
    final v = buffer[i];
    final m = v.abs();
    if (m >= threshold) buffer[i] = v < 0 ? -(m >> roi) : m >> roi;
  }
}

/// Halves a code-block's doubled magnitudes (truncating, as reversible
/// reconstruction does) into its level at ([ox], [oy]), every [step]
/// samples.
void _placeInts(
  Int32List buffer,
  int cw,
  int ch,
  Int32List level,
  int w,
  int ox,
  int oy,
  int step,
) {
  final rowStep = step * w;
  for (var j = 0, o = oy * w + ox, b = 0; j < ch; j++, o += rowStep, b += cw) {
    for (var i = 0, p = o; i < cw; i++, p += step) {
      final v = buffer[b + i];
      level[p] = v < 0 ? -((-v) >> 1) : v >> 1;
    }
  }
}

/// Dequantizes a code-block into its level at ([ox], [oy]), every [step]
/// samples.
void _placeFloats(
  Int32List buffer,
  int cw,
  int ch,
  Float64List level,
  int w,
  int ox,
  int oy,
  int step,
  double scale,
) {
  final rowStep = step * w;
  for (var j = 0, o = oy * w + ox, b = 0; j < ch; j++, o += rowStep, b += cw) {
    for (var i = 0, p = o; i < cw; i++, p += step) {
      level[p] = buffer[b + i] * scale;
    }
  }
}

/// The inverse irreversible component transform (G.3), level shift and
/// clamp of three components in one pass, straight into the output.
void _writeIct(
  Uint8List out,
  int start,
  int stride,
  int n,
  Float64List y,
  Float64List cb,
  Float64List cr,
  int from,
  int aStride,
  int cols,
  int rows,
) {
  for (var j = 0; j < rows; j++) {
    var o = start + j * stride;
    final row = from + j * aStride;
    for (var i = 0; i < cols; i++, o += n) {
      final yy = y[row + i], u = cb[row + i], v = cr[row + i];
      out[o] = _toByte(yy + 1.402 * v);
      out[o + 1] = _toByte(yy - 0.34413 * u - 0.71414 * v);
      out[o + 2] = _toByte(yy + 1.772 * u);
    }
  }
}

/// `v >> 2` for a [v] that may be negative. On the web the shift
/// operators work on unsigned 32-bit values, so a negative sample would
/// come back as a huge positive number; biasing keeps the shift positive.
@pragma('vm:prefer-inline')
@pragma('dart2js:prefer-inline')
int _shiftRight2(int v) => ((v + _shiftBias) >> 2) - (_shiftBias >> 2);

/// A multiple of four large enough to make any sample positive.
const _shiftBias = 1 << 28;

/// The same for the reversible component transform (G.2).
void _writeRct(
  Uint8List out,
  int start,
  int stride,
  int n,
  Int32List y,
  Int32List cb,
  Int32List cr,
  int from,
  int aStride,
  int cols,
  int rows,
) {
  for (var j = 0; j < rows; j++) {
    var o = start + j * stride;
    final row = from + j * aStride;
    for (var i = 0; i < cols; i++, o += n) {
      final g = y[row + i] - _shiftRight2(cb[row + i] + cr[row + i]);
      final r = cr[row + i] + g + 128;
      final b = cb[row + i] + g + 128;
      final gg = g + 128;
      out[o] = r < 0 ? 0 : (r > 255 ? 255 : r);
      out[o + 1] = gg < 0 ? 0 : (gg > 255 ? 255 : gg);
      out[o + 2] = b < 0 ? 0 : (b > 255 ? 255 : b);
    }
  }
}

/// Level-shifts, rounds half away from zero and clamps one sample.
@pragma('vm:prefer-inline')
@pragma('dart2js:prefer-inline')
int _toByte(double sample) {
  final t = sample + 128;
  final v = t >= 0 ? (t + 0.5).toInt() : -((0.5 - t).toInt());
  return v < 0 ? 0 : (v > 255 ? 255 : v);
}

/// Level-shifts, rounds and clamps a component's samples to 8 bits and
/// writes them into the interleaved output, [n] bytes apart.
void _writeInts(
  Uint8List out,
  int start,
  int stride,
  int n,
  Int32List a,
  int from,
  int aStride,
  int cols,
  int rows,
) {
  for (var j = 0; j < rows; j++) {
    var o = start + j * stride;
    final row = from + j * aStride;
    for (var i = 0; i < cols; i++, o += n) {
      final v = a[row + i] + 128;
      out[o] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
  }
}

/// Same as [_writeInts], for the irreversible transform's samples.
void _writeFloats(
  Uint8List out,
  int start,
  int stride,
  int n,
  Float64List a,
  int from,
  int aStride,
  int cols,
  int rows,
) {
  for (var j = 0; j < rows; j++) {
    var o = start + j * stride;
    final row = from + j * aStride;
    for (var i = 0; i < cols; i++, o += n) {
      out[o] = _toByte(a[row + i]);
    }
  }
}

void _shiftInts(Int32List a, int shift, int min, int max) {
  for (var i = 0; i < a.length; i++) {
    final v = a[i] + shift;
    a[i] = v < min ? min : (v > max ? max : v);
  }
}

void _shiftFloats(Float64List a, Int32List out, int shift, int min, int max) {
  for (var i = 0; i < a.length; i++) {
    // Round half away from zero, without the cost of double.round().
    final t = a[i] + shift;
    final v = t >= 0 ? (t + 0.5).toInt() : -((0.5 - t).toInt());
    out[i] = v < min ? min : (v > max ? max : v);
  }
}
