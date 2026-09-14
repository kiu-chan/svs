import 'dart:typed_data';

/// Code lengths for a Huffman code over [counts] (one entry per symbol), none
/// longer than [maxLength].
///
/// Symbols with a zero count get length 0; every other symbol gets a nonzero
/// length. With two or more used symbols the result is always a complete
/// prefix code. A lone used symbol gets length 1 — how a degenerate
/// one-symbol code is actually represented is up to the caller's format.
Uint8List huffmanCodeLengths(List<int> counts, int maxLength) {
  final lengths = Uint8List(counts.length);
  final symbols = [
    for (var s = 0; s < counts.length; s++)
      if (counts[s] > 0) s,
  ];
  if (symbols.isEmpty) return lengths;
  if (symbols.length == 1) {
    lengths[symbols.single] = 1;
    return lengths;
  }
  assert((1 << maxLength) >= symbols.length);

  final weights = [for (final s in symbols) counts[s]];
  while (true) {
    final depths = _treeDepths(weights);
    var deepest = 0;
    for (final depth in depths) {
      if (depth > deepest) deepest = depth;
    }
    if (deepest <= maxLength) {
      for (var i = 0; i < symbols.length; i++) {
        lengths[symbols[i]] = depths[i];
      }
      return lengths;
    }
    // Flattening the distribution shortens the deepest branches; once every
    // weight reaches 1 the tree is balanced, so this always terminates.
    for (var i = 0; i < weights.length; i++) {
      weights[i] = (weights[i] + 1) ~/ 2;
    }
  }
}

/// Leaf depths of a Huffman tree over [weights] (at least two), built with
/// the two-queue method.
List<int> _treeDepths(List<int> weights) {
  final n = weights.length;
  final order = List<int>.generate(n, (i) => i)
    ..sort((a, b) {
      final byWeight = weights[a].compareTo(weights[b]);
      return byWeight != 0 ? byWeight : a.compareTo(b);
    });
  final nodeCount = 2 * n - 1;
  // Leaves occupy 0..n-1 in ascending weight order; internal nodes are
  // appended after them, also in ascending weight order.
  final nodeWeights = List<int>.filled(nodeCount, 0);
  final parents = Int32List(nodeCount);
  for (var i = 0; i < n; i++) {
    nodeWeights[i] = weights[order[i]];
  }
  var nextLeaf = 0;
  var nextInternal = n;
  int takeLightest(int created) {
    if (nextLeaf < n &&
        (nextInternal >= created ||
            nodeWeights[nextLeaf] <= nodeWeights[nextInternal])) {
      return nextLeaf++;
    }
    return nextInternal++;
  }

  for (var node = n; node < nodeCount; node++) {
    final a = takeLightest(node);
    final b = takeLightest(node);
    nodeWeights[node] = nodeWeights[a] + nodeWeights[b];
    parents[a] = node;
    parents[b] = node;
  }
  final depths = Int32List(nodeCount);
  for (var node = nodeCount - 2; node >= 0; node--) {
    depths[node] = depths[parents[node]] + 1;
  }
  final result = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    result[order[i]] = depths[i];
  }
  return result;
}

/// The canonical code (RFC 1951 §3.2.2) for each symbol of [lengths] (all at
/// most 15), bit-reversed so an LSB-first bit writer emits each code
/// most-significant bit first, as both deflate and VP8L require.
Int32List canonicalCodesLsb(List<int> lengths) {
  const maxBits = 15;
  final lengthCounts = Int32List(maxBits + 1);
  for (final length in lengths) {
    if (length > 0) lengthCounts[length]++;
  }
  final nextCode = Int32List(maxBits + 1);
  var code = 0;
  for (var bits = 1; bits <= maxBits; bits++) {
    code = (code + lengthCounts[bits - 1]) << 1;
    nextCode[bits] = code;
  }
  final codes = Int32List(lengths.length);
  for (var symbol = 0; symbol < lengths.length; symbol++) {
    final length = lengths[symbol];
    if (length == 0) continue;
    var reversed = 0;
    var value = nextCode[length]++;
    for (var i = 0; i < length; i++) {
      reversed = (reversed << 1) | (value & 1);
      value >>= 1;
    }
    codes[symbol] = reversed;
  }
  return codes;
}

/// Run-length-encodes a code-length sequence with the scheme deflate and VP8L
/// share: symbols 0-15 are literal lengths, 16 repeats the previous (nonzero)
/// length 3-6 times, 17 writes 3-10 zeros, 18 writes 11-138 zeros.
///
/// Each entry packs the symbol in its low 8 bits and its extra-bits value
/// (see [codeLengthExtraBits]) above them.
List<int> runLengthEncodeCodeLengths(List<int> lengths) {
  final out = <int>[];
  var i = 0;
  while (i < lengths.length) {
    final value = lengths[i];
    var run = 1;
    while (i + run < lengths.length && lengths[i + run] == value) {
      run++;
    }
    i += run;
    if (value == 0) {
      while (run >= 11) {
        final n = run < 138 ? run : 138;
        out.add(18 | ((n - 11) << 8));
        run -= n;
      }
      if (run >= 3) {
        out.add(17 | ((run - 3) << 8));
        run = 0;
      }
    } else {
      out.add(value);
      run--;
      while (run >= 3) {
        final n = run < 6 ? run : 6;
        out.add(16 | ((n - 3) << 8));
        run -= n;
      }
    }
    for (; run > 0; run--) {
      out.add(value);
    }
  }
  return out;
}

/// Number of extra bits following code-length [symbol] (0-18).
int codeLengthExtraBits(int symbol) => switch (symbol) {
  16 => 2,
  17 => 3,
  18 => 7,
  _ => 0,
};
