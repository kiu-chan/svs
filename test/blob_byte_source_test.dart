// BlobByteSource only exists on the web (it wraps a DOM Blob), so this runs
// under `flutter test --platform chrome` only.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';
import 'package:svs/svs_web.dart';

import 'helpers/tiff_builder.dart';

@JS('Blob')
extension type _JSBlob._(JSObject _) implements JSObject {
  external factory _JSBlob(JSArray<JSAny> parts);
}

JSObject _blobOf(Uint8List bytes) => _JSBlob(<JSAny>[bytes.toJS].toJS);

void main() {
  final bytes = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));

  test('reports the blob size', () {
    expect(BlobByteSource(_blobOf(bytes)).length, 1000);
  });

  test('reads arbitrary ranges', () async {
    final source = BlobByteSource(_blobOf(bytes));
    expect(await source.readRange(0, 4), [0, 1, 2, 3]);
    expect(await source.readRange(300, 3), [44, 45, 46]);
  });

  test('is best-effort at the end, like the other sources', () async {
    final source = BlobByteSource(_blobOf(bytes));
    expect(await source.readRange(998, 10), [230, 231]);
    expect(await source.readRange(1000, 10), isEmpty);
    expect(await source.readRange(-1, 10), isEmpty);
    expect(await source.readRange(0, 0), isEmpty);
  });

  test('serves concurrent reads', () async {
    final source = BlobByteSource(_blobOf(bytes));
    final reads = await Future.wait([
      for (var i = 0; i < 10; i++) source.readRange(i * 100, 2),
    ]);
    expect(reads, [
      for (var i = 0; i < 10; i++) [(i * 100) & 0xff, (i * 100 + 1) & 0xff],
    ]);
  });

  test('rejects an object that is not a Blob', () {
    expect(() => BlobByteSource(JSObject()), throwsArgumentError);
  });

  for (final bigTiff in [false, true]) {
    test('opens a ${bigTiff ? 'BigTIFF' : 'classic TIFF'} slide', () async {
      final slide = buildTiff(
        bigTiff: bigTiff,
        order: Endian.little,
        ifds: [
          [
            TestTag.ints(256, TiffType.long, [800], Endian.little),
            TestTag.ints(257, TiffType.long, [600], Endian.little),
            TestTag.ints(259, TiffType.short, [7], Endian.little),
            TestTag.ascii(270, 'Aperio Image Library|AppMag = 20'),
            TestTag.ints(322, TiffType.long, [256], Endian.little),
            TestTag.ints(323, TiffType.long, [256], Endian.little),
            TestTag.ints(324, TiffType.long, List.filled(12, 0), Endian.little),
            TestTag.ints(325, TiffType.long, List.filled(12, 0), Endian.little),
          ],
        ],
      );

      final svs = await SvsFile.openSource(BlobByteSource(_blobOf(slide)));
      addTearDown(svs.close);

      expect(svs.path, isNull);
      expect(svs.levels[0].width, 800);
      expect(svs.levels[0].tilesAcrossX, 4);
      expect(svs.levels[0].tilesAcrossY, 3);
      expect(svs.metadata.appMag, 20);
      expect(await svs.readTileJpegBytes(0, 3, 2), isEmpty);
    });
  }
}
