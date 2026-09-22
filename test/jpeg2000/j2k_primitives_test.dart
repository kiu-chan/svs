// Round trips through the JPEG2000 building blocks. Runs on the VM and on
// the web: the codec has to be exact under dart2js's number semantics too.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/codec/jpeg2000/dwt.dart';
import 'package:svs/src/codec/jpeg2000/mq_coder.dart';
import 'package:svs/src/codec/jpeg2000/tier1.dart';

void main() {
  test('MQ coder round-trips random symbols across contexts', () {
    final random = math.Random(1);
    final symbols = <(int, int)>[
      for (var i = 0; i < 20000; i++)
        (random.nextInt(mqContextCount), random.nextInt(8) == 0 ? 1 : 0),
    ];
    final encoder = MqEncoder();
    final contexts = newMqContexts();
    for (final (cx, d) in symbols) {
      encoder.encode(contexts, cx, d);
    }
    final data = encoder.finish();

    final decoder = MqDecoder()..start(data, 0, data.length);
    final decoded = newMqContexts();
    for (final (cx, d) in symbols) {
      expect(decoder.decode(decoded, cx), d);
    }
  });

  group('DWT', () {
    final random = math.Random(2);
    for (final (x0, y0, w, h) in [
      (0, 0, 16, 16),
      (1, 0, 7, 5),
      (3, 5, 1, 9),
      (2, 7, 13, 1),
      (5, 3, 2, 3),
      (0, 1, 33, 17),
    ]) {
      test('5/3 round-trips exactly at ($x0, $y0) ${w}x$h', () {
        final a = Int32List.fromList([
          for (var i = 0; i < w * h; i++) random.nextInt(512) - 256,
        ]);
        final bands = forward53(Int32List.fromList(a), x0, y0, x0 + w, y0 + h);
        expect(inverse53(bands, x0, y0, x0 + w, y0 + h), a);
      });

      test('9/7 round-trips at ($x0, $y0) ${w}x$h', () {
        final a = Float64List.fromList([
          for (var i = 0; i < w * h; i++) random.nextDouble() * 255,
        ]);
        final bands = forward97(
          Float64List.fromList(a),
          x0,
          y0,
          x0 + w,
          y0 + h,
        );
        final back = inverse97(bands, x0, y0, x0 + w, y0 + h);
        for (var i = 0; i < a.length; i++) {
          expect(back[i], closeTo(a[i], 1e-9));
        }
      });
    }

    test('9/7 low-pass has unit DC gain', () {
      final a = Float64List(64 * 64)..fillRange(0, 64 * 64, 10);
      final bands = forward97(a, 0, 0, 64, 64);
      for (final v in bands.ll) {
        expect(v, closeTo(10, 1e-9));
      }
      for (final v in bands.hh) {
        expect(v, closeTo(0, 1e-9));
      }
    });
  });

  for (final orientation in [orientLL, orientHL, orientLH, orientHH]) {
    test('tier-1 round-trips a code-block losslessly (orientation '
        '$orientation)', () {
      final random = math.Random(3 + orientation);
      const w = 37, h = 22;
      final indices = Int32List.fromList([
        for (var i = 0; i < w * h; i++)
          random.nextInt(4) == 0 ? 0 : random.nextInt(2000) - 1000,
      ]);
      final encoded = encodeCodeBlock(
        indices: indices,
        width: w,
        height: h,
        orientation: orientation,
      );
      final out = Int32List(w * h);
      decodeCodeBlock(
        out: out,
        width: w,
        height: h,
        orientation: orientation,
        cbStyle: 0,
        bitPlanes: encoded.bitPlanes + 3,
        zeroBitPlanes: 3,
        passes: encoded.passes,
        data: encoded.data,
        segments: [
          (passes: encoded.passes, start: 0, length: encoded.data.length),
        ],
      );
      for (var i = 0; i < w * h; i++) {
        final v = out[i];
        expect(v < 0 ? -(-v >> 1) : v >> 1, indices[i], reason: 'at $i');
      }
    });
  }
}
