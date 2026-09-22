// The geometry of one tile-component (ISO/IEC 15444-1 Annex B): its
// resolution levels, their sub-bands, the precinct partition of each level
// and the code-blocks each precinct holds. Shared by the decoder, which
// fills code-blocks from packets, and the encoder, which fills them from
// coefficients.
import 'dart:typed_data';

import 'mq_coder.dart';
import 'tier1.dart';
import 'tier2.dart';

int ceilDiv(int a, int b) => (a + b - 1) ~/ b;
int ceilDivPow2(int a, int e) => (a + (1 << e) - 1) >> e;
int floorDivPow2(int a, int e) => a >> e;

/// A codeword segment being assembled from packets: how many passes it
/// may hold (set by the code-block style), holds, and its byte count.
class DecodingSegment {
  final int maxPasses;
  int passes = 0;
  int length = 0;

  DecodingSegment(this.maxPasses);
}

class CodeBlock {
  final int x0;
  final int y0;
  final int x1;
  final int y1;

  CodeBlock(this.x0, this.y0, this.x1, this.y1);

  int get width => x1 - x0;
  int get height => y1 - y0;

  // Decoding state, accumulated packet by packet.
  bool included = false;
  int zeroBitPlanes = 0;
  int lblock = 3;
  int passes = 0;
  final segments = <DecodingSegment>[];
  final chunks = <Uint8List>[];

  // Encoding state.
  EncodedCodeBlock? encoded;
  int includedPasses = 0;

  int get includedLength =>
      includedPasses == 0 ? 0 : encoded!.passLengths[includedPasses - 1];

  /// The code-block's segments laid out back to back, each followed by
  /// [segmentPadding] 0xFF bytes so tier-1 can decode it without bounds
  /// checks, and where each one starts.
  (Uint8List, List<CodewordSegment>) collectData() {
    var total = 0;
    for (final s in segments) {
      total += s.length;
    }
    final data = Uint8List(total + segmentPadding * segments.length);
    final list = <CodewordSegment>[];
    var chunk = 0;
    var chunkPos = 0;
    var o = 0;
    for (final s in segments) {
      list.add((passes: s.passes, start: o, length: s.length));
      var left = s.length;
      while (left > 0 && chunk < chunks.length) {
        final c = chunks[chunk];
        final n = c.length - chunkPos < left ? c.length - chunkPos : left;
        data.setRange(o, o + n, c, chunkPos);
        o += n;
        left -= n;
        chunkPos += n;
        if (chunkPos == c.length) {
          chunk++;
          chunkPos = 0;
        }
      }
      // Whatever the packets left short reads as 0xFF, like the padding.
      data.fillRange(o, o + left + segmentPadding, 0xFF);
      o += left + segmentPadding;
    }
    return (data, list);
  }
}

class Precinct {
  /// Code-blocks across and down, row-major in [blocks].
  final int blocksWide;
  final int blocksHigh;
  final List<CodeBlock> blocks;
  final TagTree inclusion;
  final TagTree zeroBitPlanes;

  Precinct(this.blocksWide, this.blocksHigh, this.blocks)
    : inclusion = TagTree(blocksWide, blocksHigh),
      zeroBitPlanes = TagTree(blocksWide, blocksHigh);
}

class Band {
  final int orientation;
  final int x0;
  final int y0;
  final int x1;
  final int y1;

  /// One per precinct of the resolution level, in precinct order.
  final List<Precinct> precincts;

  Band(this.orientation, this.x0, this.y0, this.x1, this.y1, this.precincts);

  int get width => x1 - x0;
  int get height => y1 - y0;

  /// Magnitude bit-planes (Mb, E-2) and, for the irreversible transform,
  /// the quantization step (E-3). Set once quantization is known.
  int bitPlanes = 0;
  double stepSize = 1;
}

class Resolution {
  final int x0;
  final int y0;
  final int x1;
  final int y1;

  /// Precinct size exponents and the precinct grid.
  final int ppx;
  final int ppy;
  final int precinctsWide;
  final int precinctsHigh;
  final List<Band> bands;

  Resolution(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.ppx,
    this.ppy,
    this.precinctsWide,
    this.precinctsHigh,
    this.bands,
  );

  int get width => x1 - x0;
  int get height => y1 - y0;
  int get precinctCount => precinctsWide * precinctsHigh;
}

/// Builds the resolution levels of a tile-component covering [x0, x1) x
/// [y0, y1) on its own sample grid, with [levels] decompositions,
/// code-blocks of `2^xcb x 2^ycb` and [precinctExponents] per level
/// (`(ppx, ppy)`, lowest resolution first).
List<Resolution> buildResolutions({
  required int x0,
  required int y0,
  required int x1,
  required int y1,
  required int levels,
  required int xcb,
  required int ycb,
  required List<(int, int)> precinctExponents,
}) {
  final resolutions = <Resolution>[];
  for (var r = 0; r <= levels; r++) {
    final levelNo = levels - r;
    final rx0 = ceilDivPow2(x0, levelNo);
    final ry0 = ceilDivPow2(y0, levelNo);
    final rx1 = ceilDivPow2(x1, levelNo);
    final ry1 = ceilDivPow2(y1, levelNo);
    final (ppx, ppy) = precinctExponents[r];
    final prcX0 = floorDivPow2(rx0, ppx) << ppx;
    final prcY0 = floorDivPow2(ry0, ppy) << ppy;
    final prcX1 = ceilDivPow2(rx1, ppx) << ppx;
    final prcY1 = ceilDivPow2(ry1, ppy) << ppy;
    final pw = rx0 == rx1 ? 0 : (prcX1 - prcX0) >> ppx;
    final ph = ry0 == ry1 ? 0 : (prcY1 - prcY0) >> ppy;

    // Precincts and code-blocks in sub-band coordinates: a level's
    // precinct partition halves in its high-pass bands.
    final int cbgX0, cbgY0, cbgW, cbgH;
    if (r == 0) {
      cbgX0 = prcX0;
      cbgY0 = prcY0;
      cbgW = ppx;
      cbgH = ppy;
    } else {
      cbgX0 = ceilDivPow2(prcX0, 1);
      cbgY0 = ceilDivPow2(prcY0, 1);
      cbgW = ppx - 1;
      cbgH = ppy - 1;
    }
    final cbW = xcb < cbgW ? xcb : cbgW;
    final cbH = ycb < cbgH ? ycb : cbgH;

    final bands = <Band>[];
    for (final orientation
        in r == 0 ? const [orientLL] : const [orientHL, orientLH, orientHH]) {
      final int bx0, by0, bx1, by1;
      if (r == 0) {
        bx0 = rx0;
        by0 = ry0;
        bx1 = rx1;
        by1 = ry1;
      } else {
        final xob = orientation & 1;
        final yob = orientation >> 1;
        bx0 = ceilDivPow2(x0 - (xob << levelNo), levelNo + 1);
        by0 = ceilDivPow2(y0 - (yob << levelNo), levelNo + 1);
        bx1 = ceilDivPow2(x1 - (xob << levelNo), levelNo + 1);
        by1 = ceilDivPow2(y1 - (yob << levelNo), levelNo + 1);
      }
      final precincts = <Precinct>[];
      for (var p = 0; p < pw * ph; p++) {
        final gx0 = cbgX0 + (p % pw) * (1 << cbgW);
        final gy0 = cbgY0 + (p ~/ pw) * (1 << cbgH);
        final px0 = gx0 > bx0 ? gx0 : bx0;
        final py0 = gy0 > by0 ? gy0 : by0;
        final px1 = gx0 + (1 << cbgW) < bx1 ? gx0 + (1 << cbgW) : bx1;
        final py1 = gy0 + (1 << cbgH) < by1 ? gy0 + (1 << cbgH) : by1;
        if (px0 >= px1 || py0 >= py1) {
          precincts.add(Precinct(0, 0, const []));
          continue;
        }
        final cbx0 = floorDivPow2(px0, cbW) << cbW;
        final cby0 = floorDivPow2(py0, cbH) << cbH;
        final cw = ((ceilDivPow2(px1, cbW) << cbW) - cbx0) >> cbW;
        final ch = ((ceilDivPow2(py1, cbH) << cbH) - cby0) >> cbH;
        final blocks = <CodeBlock>[];
        for (var j = 0; j < ch; j++) {
          for (var i = 0; i < cw; i++) {
            final bx = cbx0 + (i << cbW);
            final by = cby0 + (j << cbH);
            blocks.add(
              CodeBlock(
                bx > px0 ? bx : px0,
                by > py0 ? by : py0,
                bx + (1 << cbW) < px1 ? bx + (1 << cbW) : px1,
                by + (1 << cbH) < py1 ? by + (1 << cbH) : py1,
              ),
            );
          }
        }
        precincts.add(Precinct(cw, ch, blocks));
      }
      bands.add(Band(orientation, bx0, by0, bx1, by1, precincts));
    }
    resolutions.add(Resolution(rx0, ry0, rx1, ry1, ppx, ppy, pw, ph, bands));
  }
  return resolutions;
}
