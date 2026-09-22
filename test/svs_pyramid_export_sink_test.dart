// Runs on the VM and on the web (`flutter test --platform chrome`): the
// *ToSink exports are how the web streams a large export to disk, so they
// need to produce exactly what the in-memory exports do, everywhere.

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/errors.dart';
import 'package:svs/src/io/byte_sink.dart';
import 'package:svs/src/render/svs_pyramid_export.dart';
import 'package:svs/src/render/svs_pyramid_rebuild.dart';
import 'package:svs/src/svs/svs_file.dart';

import 'helpers/jpeg_slide_builder.dart';

void main() {
  late SvsFile svs;

  setUp(() async {
    svs = await SvsFile.openBytes(buildJpegTiledSlide(width: 600, height: 400));
  });

  tearDown(() => svs.close());

  test('exportSvsRegionAsSvsToSink writes what exportSvsRegionAsSvs '
      'returns, and leaves the sink open', () async {
    final expected = await exportSvsRegionAsSvs(
      svs,
      level: 0,
      x: 40,
      y: 30,
      width: 500,
      height: 350,
      tileSize: 128,
    );

    final sink = _RecordingSink();
    await exportSvsRegionAsSvsToSink(
      svs,
      sink: sink,
      level: 0,
      x: 40,
      y: 30,
      width: 500,
      height: 350,
      tileSize: 128,
    );

    expect(sink.closed, isFalse);
    expect(sink.toBytes(), expected);

    final exported = await SvsFile.openBytes(sink.toBytes());
    addTearDown(exported.close);
    expect(exported.levels.map((l) => (l.width, l.height)), [
      (500, 350),
      (250, 175),
      (125, 88),
    ]);
  });

  test('exportSvsRegionAsSvsPreservingLevelsToSink writes what '
      'exportSvsRegionAsSvsPreservingLevels returns', () async {
    final expected = await exportSvsRegionAsSvsPreservingLevels(
      svs,
      level: 0,
      x: 0,
      y: 0,
      width: 300,
      height: 200,
    );

    final sink = _RecordingSink();
    await exportSvsRegionAsSvsPreservingLevelsToSink(
      svs,
      sink: sink,
      level: 0,
      x: 0,
      y: 0,
      width: 300,
      height: 200,
    );

    expect(sink.closed, isFalse);
    expect(sink.toBytes(), expected);
  });

  test('rebuildSvsPyramidToSink writes what rebuildSvsPyramid '
      'returns', () async {
    final expected = await rebuildSvsPyramid(svs, levelCount: 2);

    final sink = _RecordingSink();
    await rebuildSvsPyramidToSink(svs, sink: sink, levelCount: 2);

    expect(sink.closed, isFalse);
    expect(sink.toBytes(), expected);
  });

  test('a failed export leaves the sink open too', () async {
    final sink = _RecordingSink();
    await expectLater(
      exportSvsRegionAsSvsToSink(
        svs,
        sink: sink,
        level: 5,
        x: 0,
        y: 0,
        width: 10,
        height: 10,
      ),
      throwsA(isA<SvsFormatException>()),
    );
    expect(sink.closed, isFalse);
  });
}

class _RecordingSink extends MemoryByteSink {
  var closed = false;

  @override
  Future<void> close() async => closed = true;
}
