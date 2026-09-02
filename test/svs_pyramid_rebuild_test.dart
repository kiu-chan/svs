@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:svs/src/render/svs_pyramid_rebuild.dart';
import 'package:svs/src/render/svs_pyramid_rebuild_to_file.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

/// Builds a real, decodable single-tile JPEG-compressed source `.svs`
/// fixture: a [size]x[size] image, one [size]x[size] tile, solid-filled with
/// [color]. Same shape/rationale as the identically-named helper in
/// `svs_pyramid_export_test.dart` — duplicated rather than shared, matching
/// this package's existing per-test-file fixture convention.
Future<File> _buildSingleTileJpegFixture(
  Directory dir,
  String name, {
  required int size,
  required (int, int, int) color,
}) async {
  final tile = img.Image(width: size, height: size);
  img.fill(tile, color: img.ColorRgb8(color.$1, color.$2, color.$3));
  final tileJpeg = img.encodeJpg(tile, quality: 95);

  List<TestTag> tags(int tileOffset) => [
    TestTag.ints(256, TiffType.long, [size], Endian.little),
    TestTag.ints(257, TiffType.long, [size], Endian.little),
    TestTag.ints(259, TiffType.short, [7], Endian.little), // new-style JPEG
    TestTag.ints(322, TiffType.long, [size], Endian.little),
    TestTag.ints(323, TiffType.long, [size], Endian.little),
    TestTag.ints(324, TiffType.long, [tileOffset], Endian.little),
    TestTag.ints(325, TiffType.long, [tileJpeg.length], Endian.little),
  ];

  final headerOnly = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [tags(0)],
  );
  final realOffset = headerOnly.length;
  final header = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [tags(realOffset)],
  );
  expect(header.length, realOffset);

  final file = File('${dir.path}/$name');
  await file.writeAsBytes([...header, ...tileJpeg]);
  return file;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('svs_pyramid_rebuild_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('rebuildSvsPyramid regenerates the whole slide as a smoother pyramid',
      () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 512,
      color: (10, 150, 220),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);
    // A source with only one on-disk level (no coarser levels at all).
    expect(svs.levels.length, 1);

    final outBytes = await rebuildSvsPyramid(svs, tileSize: 256);

    final outFile = File('${tempDir.path}/out.svs');
    await outFile.writeAsBytes(outBytes);
    final roundTripped = await SvsFile.open(outFile.path);
    addTearDown(roundTripped.close);

    expect(roundTripped.levels[0].width, 512);
    expect(roundTripped.levels[0].height, 512);
    // Auto (levelCount: null) generates the full smooth cascade down to one
    // tile — more levels than the single-level source had.
    expect(roundTripped.levels.length, 2);
    expect(roundTripped.levels[1].width, 256);
    expect(roundTripped.levels[1].height, 256);
  });

  test('rebuildSvsPyramid levelCount decreases the level count relative to '
      'the auto/natural cascade', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 800,
      color: (30, 180, 90),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final outBytes = await rebuildSvsPyramid(
      svs,
      tileSize: 128,
      levelCount: 2,
    );

    final outFile = File('${tempDir.path}/out.svs');
    await outFile.writeAsBytes(outBytes);
    final roundTripped = await SvsFile.open(outFile.path);
    addTearDown(roundTripped.close);

    expect(roundTripped.levels.length, 2);
  });

  test('rebuildSvsPyramidToFile writes a new file next to the original, '
      'leaving it untouched', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
    );
    final originalBytes = await file.readAsBytes();
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final outPath = '${tempDir.path}/src.rebuilt.svs';
    // rebuildSvsPyramidToFile/rebuildSvsPyramidInPlace only exist in the
    // dart:io conditional-export branch — see the identical comment on
    // exportSvsRegionAsSvsToFile's own test in svs_pyramid_export_test.dart.
    // ignore: undefined_function
    final outFile = await rebuildSvsPyramidToFile(svs, path: outPath);
    expect(outFile.path, outPath);

    final roundTripped = await SvsFile.open(outPath);
    addTearDown(roundTripped.close);
    expect(roundTripped.levels[0].width, 64);
    expect(roundTripped.levels[0].height, 64);

    expect(await file.readAsBytes(), equals(originalBytes));
  });

  group('rebuildSvsPyramidInPlace', () {
    test('overwrites the source file and returns a reopened handle on it',
        () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 800,
        color: (30, 180, 90),
      );
      final originalPath = file.path;
      final svs = await SvsFile.open(originalPath);
      // Not `addTearDown(svs.close)` — rebuildSvsPyramidInPlace closes it
      // internally once the rebuild succeeds.

      // ignore: undefined_function
      final rebuilt = await rebuildSvsPyramidInPlace(
        svs,
        tileSize: 128,
        levelCount: 2,
      );
      addTearDown(rebuilt.close);

      expect(rebuilt.path, originalPath);
      expect(rebuilt.levels.length, 2);
      expect(rebuilt.levels[0].width, 800);
      expect(rebuilt.levels[1].width, 400);

      // No leftover temp file.
      expect(await File('$originalPath.rebuild.tmp').exists(), isFalse);

      // The path itself now really does hold the rebuilt file, independent
      // of the returned handle.
      final reopened = await SvsFile.open(originalPath);
      addTearDown(reopened.close);
      expect(reopened.levels.length, 2);
    });

    test('throws for a file opened via openBytes (no path to overwrite)',
        () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (200, 100, 50),
      );
      final bytes = await file.readAsBytes();
      final svs = await SvsFile.openBytes(bytes);
      addTearDown(svs.close);

      expect(
        // ignore: undefined_function
        () => rebuildSvsPyramidInPlace(svs),
        throwsArgumentError,
      );
    });

    test('a failed rebuild leaves the original file untouched and cleans up '
        'the temp file', () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (200, 100, 50),
      );
      final originalPath = file.path;
      final originalBytes = await file.readAsBytes();
      final svs = await SvsFile.open(originalPath);
      addTearDown(svs.close);

      await expectLater(
        // levelCount: 0 fails validation inside the streaming core, after
        // the temp file has already been created but before any of its
        // real content is written — exercising the cleanup path without
        // needing to fabricate a deeper mid-stream failure.
        // ignore: undefined_function
        rebuildSvsPyramidInPlace(svs, levelCount: 0),
        throwsArgumentError,
      );

      expect(await File('$originalPath.rebuild.tmp').exists(), isFalse);
      expect(await file.readAsBytes(), equals(originalBytes));

      // svsFile itself was never closed by the failed attempt — still
      // usable.
      expect(svs.levels.single.width, 64);
    });
  });
}
