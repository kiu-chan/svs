// SvsFile.openBytes and SvsFile.openSource are the entry points for
// platforms with no filesystem (the web) — this test proves they behave
// identically to SvsFile.open(path) for the operations that matter, and runs
// on every platform (including web), unlike most of this package's other
// SvsFile tests which write a fixture to a real file via dart:io and are
// tagged @TestOn('vm').
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/errors.dart';
import 'package:svs/src/io/byte_source.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

/// A single-level slide. Every tile is sparse (byte count 0) unless
/// [tileOffsets]/[tileByteCounts] say otherwise — no real JPEG bytes are
/// needed to exercise level/tile geometry.
Uint8List _buildSparseSingleLevelSvs({
  required int width,
  required int height,
  required int tileSize,
  bool bigTiff = false,
  List<int>? tileOffsets,
  List<int>? tileByteCounts,
}) {
  final tilesX = (width / tileSize).ceil();
  final tilesY = (height / tileSize).ceil();
  final tileCount = tilesX * tilesY;
  return buildTiff(
    bigTiff: bigTiff,
    order: Endian.little,
    ifds: [
      [
        TestTag.ints(256, TiffType.long, [width], Endian.little),
        TestTag.ints(257, TiffType.long, [height], Endian.little),
        TestTag.ints(259, TiffType.short, [7], Endian.little), // new JPEG
        TestTag.ascii(
          270,
          'Aperio Image Library v11.2.1\r\n${width}x$height '
          '[0,0 ${width}x$height] ($tileSize x $tileSize) JPEG/RGB Q=30'
          '|AppMag = 20|MPP = 0.4990',
        ),
        TestTag.ints(322, TiffType.long, [tileSize], Endian.little),
        TestTag.ints(323, TiffType.long, [tileSize], Endian.little),
        TestTag.ints(
          324,
          TiffType.long,
          tileOffsets ?? List.filled(tileCount, 0),
          Endian.little,
        ),
        TestTag.ints(
          325,
          TiffType.long,
          tileByteCounts ?? List.filled(tileCount, 0),
          Endian.little,
        ),
      ],
    ],
  );
}

void main() {
  test(
    'openBytes parses levels/metadata the same as open(path) does',
    () async {
      final bytes = _buildSparseSingleLevelSvs(
        width: 800,
        height: 600,
        tileSize: 256,
      );

      final svs = await SvsFile.openBytes(bytes);
      addTearDown(svs.close);

      expect(svs.path, isNull);
      expect(svs.levels, hasLength(1));
      expect(svs.levels[0].width, 800);
      expect(svs.levels[0].height, 600);
      expect(svs.levels[0].tilesAcrossX, 4);
      expect(svs.levels[0].tilesAcrossY, 3);
      expect(svs.metadata.appMag, 20);
      expect(svs.metadata.mppX, closeTo(0.4990, 1e-9));
    },
  );

  test('openBytes reads tile bytes the same as open(path) does', () async {
    final bytes = _buildSparseSingleLevelSvs(
      width: 256,
      height: 256,
      tileSize: 256,
    );

    final svs = await SvsFile.openBytes(bytes);
    addTearDown(svs.close);

    // A sparse tile (byte count 0) reads back as empty, not an error —
    // same contract as the path-based SvsFile.open.
    final tile = await svs.readTileJpegBytes(0, 0, 0);
    expect(tile, isEmpty);
  });

  test('openBytes opens a BigTIFF slide', () async {
    // BigTIFF's 64-bit offsets are what used to throw on the web.
    final bytes = _buildSparseSingleLevelSvs(
      width: 800,
      height: 600,
      tileSize: 256,
      bigTiff: true,
    );

    final svs = await SvsFile.openBytes(bytes);
    addTearDown(svs.close);

    expect(svs.levels, hasLength(1));
    expect(svs.levels[0].tilesAcrossX, 4);
    expect(svs.levels[0].tilesAcrossY, 3);
    expect(svs.metadata.appMag, 20);
    expect(await svs.readTileJpegBytes(0, 3, 2), isEmpty);
  });

  test('openBytes rejects a corrupt/too-short buffer the same way open '
      'rejects a corrupt file', () async {
    await expectLater(
      SvsFile.openBytes(Uint8List.fromList([1, 2, 3])),
      throwsA(anything),
    );
  });

  group('openSource', () {
    test('reads only the directories, then just the tiles asked for', () async {
      // Two 256 KB tiles stored after the TIFF structure. Their offsets
      // don't change the structure's length (fixed-size LONG values), so
      // build once to measure it, then again with the real offsets.
      const tileBytes = 256 * 1024;
      Uint8List build(int dataStart) => _buildSparseSingleLevelSvs(
        width: 512,
        height: 256,
        tileSize: 256,
        tileOffsets: [dataStart, dataStart + tileBytes],
        tileByteCounts: [tileBytes, tileBytes],
      );
      final dataStart = build(0).length;
      final slide = Uint8List(dataStart + 2 * tileBytes)
        ..setAll(0, build(dataStart));
      for (var i = 0; i < tileBytes; i++) {
        slide[dataStart + tileBytes + i] = i & 0xff;
      }

      final source = _RecordingSource(slide);
      final svs = await SvsFile.openSource(source);
      addTearDown(svs.close);

      expect(svs.path, isNull);
      expect(svs.levels[0].tilesAcrossX, 2);
      expect(source.bytesRead, lessThan(dataStart + 1));

      final readBefore = source.bytesRead;
      final tile = await svs.readTileJpegBytes(0, 1, 0);
      expect(tile, hasLength(tileBytes));
      expect(tile.sublist(0, 4), [0, 1, 2, 3]);
      expect(source.reads, contains((dataStart + tileBytes, tileBytes)));
      // The other tile was never read.
      expect(source.bytesRead - readBefore, lessThan(tileBytes + 4096));
    });

    test('close closes the source', () async {
      final source = _RecordingSource(
        _buildSparseSingleLevelSvs(width: 256, height: 256, tileSize: 256),
      );
      final svs = await SvsFile.openSource(source);
      expect(source.closed, isFalse);
      await svs.close();
      expect(source.closed, isTrue);
    });

    test('closes the source when the slide fails to open', () async {
      final source = _RecordingSource(Uint8List.fromList([1, 2, 3]));
      await expectLater(
        SvsFile.openSource(source),
        throwsA(isA<SvsFormatException>()),
      );
      expect(source.closed, isTrue);
    });
  });
}

/// Serves [_bytes] like `openBytes` does, but records every read and
/// whether it was closed.
class _RecordingSource implements RandomAccessByteSource {
  final MemoryByteSource _bytes;
  final reads = <(int, int)>[];
  var closed = false;

  _RecordingSource(Uint8List bytes) : _bytes = MemoryByteSource(bytes);

  int get bytesRead => reads.fold(0, (sum, read) => sum + read.$2);

  @override
  Future<Uint8List> readRange(int offset, int length) {
    reads.add((offset, length));
    return _bytes.readRange(offset, length);
  }

  @override
  Future<void> close() async => closed = true;
}
