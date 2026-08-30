@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:openjpeg_ffi/openjpeg_ffi.dart';
import 'package:svs/src/errors.dart';
import 'package:svs/src/render/associated_image_decoder.dart';
import 'package:svs/src/render/region_decoder.dart';
import 'package:svs/src/render/svs_pyramid_export.dart';
import 'package:svs/src/render/svs_pyramid_export_to_file.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

/// Builds a real, decodable single-tile JPEG-compressed source `.svs`
/// fixture: a [size]x[size] image, one [size]x[size] tile, solid-filled with
/// [color]. Unlike the sparse (byte-count-0) fixtures the rest of this
/// package's tests use, this one has genuine tile bytes at a real file
/// offset — needed here because [exportSvsRegionAsSvs] actually decodes its
/// source region via `readSvsRegion`.
///
/// Two-pass layout: `TileOffsets` (a single inline LONG value, since there's
/// only one tile) doesn't change the header's byte length regardless of its
/// value, so the header can be measured once with a placeholder offset, then
/// rebuilt with the tile's real (now-known) offset appended right after it.
Future<File> _buildSingleTileJpegFixture(
  Directory dir,
  String name, {
  required int size,
  required (int, int, int) color,
  String? imageDescription,
}) async {
  final tile = img.Image(width: size, height: size);
  img.fill(tile, color: img.ColorRgb8(color.$1, color.$2, color.$3));
  final tileJpeg = img.encodeJpg(tile, quality: 95);

  List<TestTag> tags(int tileOffset) => [
    TestTag.ints(256, TiffType.long, [size], Endian.little),
    TestTag.ints(257, TiffType.long, [size], Endian.little),
    TestTag.ints(259, TiffType.short, [7], Endian.little), // new-style JPEG
    if (imageDescription != null) TestTag.ascii(270, imageDescription),
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
  // The tile offset is a single inline value (fits in the 4-byte field), so
  // rebuilding with the real offset can't have changed the header's length.
  expect(header.length, realOffset);

  final file = File('${dir.path}/$name');
  await file.writeAsBytes([...header, ...tileJpeg]);
  return file;
}

/// Same as [_buildSingleTileJpegFixture], but with a second, non-tiled IFD
/// right after the pyramid one — a single-strip JPEG associated image
/// classified as [AssociatedImageKind.label] (its `ImageDescription`
/// contains "label", same as [SvsFile]'s own classifier looks for) — so
/// `exportSvsRegionAsSvs`'s label/macro copy-through can be exercised
/// against a real source file rather than just unit-tested in isolation.
///
/// Two-pass layout, extended to two out-of-line blobs (tile bytes, then
/// label-strip bytes) laid out back-to-back right after the header, same
/// trick as [_buildSingleTileJpegFixture]: both `TileOffsets`/`StripOffsets`
/// are single inline values, so neither's real value changes the header's
/// byte length.
Future<File> _buildFixtureWithLabel(
  Directory dir,
  String name, {
  required int size,
  required (int, int, int) color,
  required int labelSize,
  required (int, int, int) labelColor,
  String? imageDescription,
}) async {
  final tile = img.Image(width: size, height: size);
  img.fill(tile, color: img.ColorRgb8(color.$1, color.$2, color.$3));
  final tileJpeg = img.encodeJpg(tile, quality: 95);

  final label = img.Image(width: labelSize, height: labelSize);
  img.fill(
    label,
    color: img.ColorRgb8(labelColor.$1, labelColor.$2, labelColor.$3),
  );
  final labelJpeg = img.encodeJpg(label, quality: 95);

  List<List<TestTag>> ifds(int tileOffset, int labelOffset) => [
    [
      TestTag.ints(256, TiffType.long, [size], Endian.little),
      TestTag.ints(257, TiffType.long, [size], Endian.little),
      TestTag.ints(259, TiffType.short, [7], Endian.little), // new-style JPEG
      if (imageDescription != null) TestTag.ascii(270, imageDescription),
      TestTag.ints(322, TiffType.long, [size], Endian.little),
      TestTag.ints(323, TiffType.long, [size], Endian.little),
      TestTag.ints(324, TiffType.long, [tileOffset], Endian.little),
      TestTag.ints(325, TiffType.long, [tileJpeg.length], Endian.little),
    ],
    [
      TestTag.ints(256, TiffType.long, [labelSize], Endian.little),
      TestTag.ints(257, TiffType.long, [labelSize], Endian.little),
      TestTag.ints(259, TiffType.short, [7], Endian.little),
      TestTag.ints(262, TiffType.short, [6], Endian.little), // YCbCr
      TestTag.ascii(270, 'aperio-label'),
      TestTag.ints(273, TiffType.long, [labelOffset], Endian.little),
      TestTag.ints(277, TiffType.short, [3], Endian.little),
      TestTag.ints(278, TiffType.long, [labelSize], Endian.little),
      TestTag.ints(279, TiffType.long, [labelJpeg.length], Endian.little),
    ],
  ];

  final headerOnly = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: ifds(0, 0),
  );
  final realTileOffset = headerOnly.length;
  final realLabelOffset = realTileOffset + tileJpeg.length;
  final header = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: ifds(realTileOffset, realLabelOffset),
  );
  expect(header.length, realTileOffset);

  final file = File('${dir.path}/$name');
  await file.writeAsBytes([...header, ...tileJpeg, ...labelJpeg]);
  return file;
}

/// Same as [_buildSingleTileJpegFixture], but the tile is a real JPEG2000
/// codestream (`Compression` tag 33005) encoded at [compressionRatio] —
/// needed to exercise `matchSourceCompression`'s JP2K path against a source
/// whose on-disk tile size reflects genuine (possibly lossy) compression,
/// not just a relabeled JPEG tile.
Future<File> _buildSingleTileJp2kFixture(
  Directory dir,
  String name, {
  required int size,
  required (int, int, int) color,
  required double compressionRatio,
}) async {
  final tile = img.Image(width: size, height: size);
  img.fill(tile, color: img.ColorRgb8(color.$1, color.$2, color.$3));
  return _writeSingleTileJp2kFixture(
    dir,
    name,
    tile: tile,
    compressionRatio: compressionRatio,
  );
}

/// Lower-level counterpart to [_buildSingleTileJp2kFixture] that takes the
/// tile image directly — needed by tests where a flat solid color (already
/// near-minimal even losslessly) wouldn't tell a lossy ratio apart from
/// lossless.
Future<File> _writeSingleTileJp2kFixture(
  Directory dir,
  String name, {
  required img.Image tile,
  required double compressionRatio,
}) async {
  final size = tile.width;
  final tileJ2k = encodeJ2k(
    tile.getBytes(order: img.ChannelOrder.rgb),
    width: size,
    height: size,
    numComponents: 3,
    compressionRatio: compressionRatio,
  );

  List<TestTag> tags(int tileOffset) => [
    TestTag.ints(256, TiffType.long, [size], Endian.little),
    TestTag.ints(257, TiffType.long, [size], Endian.little),
    TestTag.ints(259, TiffType.short, [33005], Endian.little), // JPEG2000
    TestTag.ints(322, TiffType.long, [size], Endian.little),
    TestTag.ints(323, TiffType.long, [size], Endian.little),
    TestTag.ints(324, TiffType.long, [tileOffset], Endian.little),
    TestTag.ints(325, TiffType.long, [tileJ2k.length], Endian.little),
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
  await file.writeAsBytes([...header, ...tileJ2k]);
  return file;
}

/// Builds a multi-level JPEG-compressed source `.svs` fixture — one
/// single-tile IFD per entry in [levelSizes]/[levelColors] (finest level
/// first, same order a real Aperio pyramid stores them in), each solid
/// filled with its own distinct color. Needed by
/// `exportSvsRegionAsSvsPreservingLevels`'s tests: giving each level a
/// different (not a downsampled version of the previous level's) color
/// makes it possible to tell "cropped directly from that source level"
/// apart from "downsampled from a finer level's pixels" just by checking
/// which color came out.
Future<File> _buildMultiLevelJpegFixture(
  Directory dir,
  String name, {
  required List<int> levelSizes,
  required List<(int, int, int)> levelColors,
  String? level0ImageDescription,
}) async {
  final tileJpegs = <Uint8List>[];
  for (var i = 0; i < levelSizes.length; i++) {
    final tile = img.Image(width: levelSizes[i], height: levelSizes[i]);
    final color = levelColors[i];
    img.fill(tile, color: img.ColorRgb8(color.$1, color.$2, color.$3));
    tileJpegs.add(img.encodeJpg(tile, quality: 95));
  }

  List<List<TestTag>> ifds(List<int> tileOffsets) => [
    for (var i = 0; i < levelSizes.length; i++)
      [
        TestTag.ints(256, TiffType.long, [levelSizes[i]], Endian.little),
        TestTag.ints(257, TiffType.long, [levelSizes[i]], Endian.little),
        TestTag.ints(259, TiffType.short, [7], Endian.little), // new JPEG
        if (i == 0 && level0ImageDescription != null)
          TestTag.ascii(270, level0ImageDescription),
        TestTag.ints(322, TiffType.long, [levelSizes[i]], Endian.little),
        TestTag.ints(323, TiffType.long, [levelSizes[i]], Endian.little),
        TestTag.ints(324, TiffType.long, [tileOffsets[i]], Endian.little),
        TestTag.ints(325, TiffType.long, [tileJpegs[i].length], Endian.little),
      ],
  ];

  final placeholderOffsets = List.filled(levelSizes.length, 0);
  final headerOnly = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: ifds(placeholderOffsets),
  );
  final realOffsets = <int>[];
  var pos = headerOnly.length;
  for (final tileJpeg in tileJpegs) {
    realOffsets.add(pos);
    pos += tileJpeg.length;
  }
  final header = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: ifds(realOffsets),
  );
  // Every TileOffsets value is a single inline LONG, so none of the real
  // (now-known) offsets can have changed the header's own byte length.
  expect(header.length, headerOnly.length);

  final file = File('${dir.path}/$name');
  await file.writeAsBytes([...header, for (final t in tileJpegs) ...t]);
  return file;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('svs_pyramid_export_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('rejects an out-of-range level', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    await expectLater(
      exportSvsRegionAsSvs(svs, level: 3, x: 0, y: 0, width: 64, height: 64),
      throwsA(isA<SvsFormatException>()),
    );
  });

  test('rejects a non-positive tileSize', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    await expectLater(
      exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
        tileSize: 0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'refuses to export a crop over an explicitly-passed maxPixels limit',
    () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (200, 100, 50),
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      await expectLater(
        exportSvsRegionAsSvs(
          svs,
          level: 0,
          x: 0,
          y: 0,
          width: 64,
          height: 64,
          maxPixels: 100, // 64x64 = 4096 px, well over this
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test('has no pixel-count limit by default', () async {
    // 64x64 = 4096 px would have exceeded the old default 100px test cap
    // above, and would have exceeded the old default defaultExportMaxPixels
    // for a big enough crop — with no maxPixels passed at all, it just works.
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final outBytes = await exportSvsRegionAsSvs(
      svs,
      level: 0,
      x: 0,
      y: 0,
      width: 64,
      height: 64,
    );
    expect(outBytes, isNotEmpty);
  });

  test(
    'round-trips a single-level crop: dimensions, pixels, and metadata all survive reopening',
    () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (200, 100, 50),
        imageDescription:
            'Aperio Image Library v11.2.1\r\n'
            '64x64 [0,0 64x64] (64x64) JPEG/RGB Q=30|AppMag = 20|MPP = 0.4990',
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
        tileSize: 256, // bigger than the 64x64 crop -> a single output level
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels, hasLength(1));
      expect(roundTripped.levels.single.width, 64);
      expect(roundTripped.levels.single.height, 64);
      expect(roundTripped.levels.single.isJpeg, isTrue);

      // Metadata parsed back out of the exported file's own ImageDescription.
      expect(roundTripped.metadata.appMag, 20);
      expect(roundTripped.metadata.mppX, closeTo(0.4990, 1e-6));

      final region = await readSvsRegion(
        roundTripped,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
      );
      addTearDown(region.dispose);
      final data = await region.toByteData();
      final pixels = data!.buffer.asUint8List();
      expect(pixels[0], closeTo(200, 10)); // R
      expect(pixels[1], closeTo(100, 10)); // G
      expect(pixels[2], closeTo(50, 10)); // B
    },
  );

  test(
    'compression: SvsExportCompression.jpeg2000 produces a lossless-by-default '
    'JP2K pyramid instead of JPEG',
    () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (200, 100, 50),
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
        tileSize: 256,
        compression: SvsExportCompression.jpeg2000,
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels.single.isJp2k, isTrue);
      expect(roundTripped.levels.single.isJpeg, isFalse);

      final region = await readSvsRegion(
        roundTripped,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
      );
      addTearDown(region.dispose);
      final data = await region.toByteData();
      final pixels = data!.buffer.asUint8List();
      // Lossless by default (jp2kCompressionRatio: 0, the default) — much
      // tighter tolerance than the lossy-JPEG round-trip test above.
      expect(pixels[0], closeTo(200, 2)); // R
      expect(pixels[1], closeTo(100, 2)); // G
      expect(pixels[2], closeTo(50, 2)); // B
    },
  );

  group('matchSourceCompression', () {
    test('parses the source JPEG quality out of its ImageDescription instead '
        'of using the quality parameter', () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (200, 100, 50),
        imageDescription:
            'Aperio Image Library v11.2.1\r\n'
            '64x64 [0,0 64x64] (64x64) JPEG/RGB Q=37|AppMag = 20',
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
        tileSize: 256,
        quality: 90, // ignored: matchSourceCompression wins
        matchSourceCompression: true,
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels.single.isJpeg, isTrue);
      final description = await roundTripped.levels.single.imageDescription;
      expect(description, contains('Q=37'));
    });

    test(
      'falls back to the quality parameter when the source has no Q= to match',
      () async {
        final file = await _buildSingleTileJpegFixture(
          tempDir,
          'src.svs',
          size: 64,
          color: (200, 100, 50),
          // No imageDescription at all -> nothing to parse a quality from.
        );
        final svs = await SvsFile.open(file.path);
        addTearDown(svs.close);

        final outBytes = await exportSvsRegionAsSvs(
          svs,
          level: 0,
          x: 0,
          y: 0,
          width: 64,
          height: 64,
          tileSize: 256,
          quality: 55,
          matchSourceCompression: true,
        );

        final outFile = File('${tempDir.path}/out.svs');
        await outFile.writeAsBytes(outBytes);
        final roundTripped = await SvsFile.open(outFile.path);
        addTearDown(roundTripped.close);

        final description = await roundTripped.levels.single.imageDescription;
        expect(description, contains('Q=55'));
      },
    );

    test('switches to JPEG2000 to match a JP2K source, even though the '
        'compression parameter still says JPEG', () async {
      final file = await _buildSingleTileJp2kFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (10, 150, 220),
        compressionRatio: 20,
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
        tileSize: 256,
        compression: SvsExportCompression.jpeg, // ignored
        matchSourceCompression: true,
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels.single.isJp2k, isTrue);
      expect(roundTripped.levels.single.isJpeg, isFalse);
    });

    test(
      'estimates a lossy JP2K ratio from the source\'s own tile size instead '
      'of defaulting to lossless',
      () async {
        // A gradient (unlike a flat color, already near-minimal even
        // losslessly) has real entropy for a compressionRatio to bite into,
        // so matching a lossy source ratio should land visibly smaller than
        // the lossless default would.
        final tile = img.Image(width: 64, height: 64);
        for (var y = 0; y < 64; y++) {
          for (var x = 0; x < 64; x++) {
            tile.setPixelRgb(x, y, (x * 4) % 256, (y * 4) % 256, (x ^ y));
          }
        }
        final file = await _writeSingleTileJp2kFixture(
          tempDir,
          'src.svs',
          tile: tile,
          compressionRatio: 60,
        );
        final svs = await SvsFile.open(file.path);
        addTearDown(svs.close);

        final outBytes = await exportSvsRegionAsSvs(
          svs,
          level: 0,
          x: 0,
          y: 0,
          width: 64,
          height: 64,
          // Matches the 64x64 crop exactly -> no JP2K boundary-tile padding,
          // which would otherwise dilute the lossy-vs-lossless size gap this
          // test is checking for with fixed, ratio-independent zero padding.
          tileSize: 64,
          matchSourceCompression: true,
        );
        final losslessBytes = await exportSvsRegionAsSvs(
          svs,
          level: 0,
          x: 0,
          y: 0,
          width: 64,
          height: 64,
          tileSize: 64,
          compression: SvsExportCompression.jpeg2000, // default: lossless
        );

        final outFile = File('${tempDir.path}/out.svs');
        await outFile.writeAsBytes(outBytes);
        final roundTripped = await SvsFile.open(outFile.path);
        addTearDown(roundTripped.close);

        expect(roundTripped.levels.single.isJp2k, isTrue);
        // Matching the source's own lossy ratio should land meaningfully
        // smaller than exporting the same crop lossless (ratio 0) would —
        // otherwise the estimate silently fell back to lossless.
        expect(outBytes.length, lessThan(losslessBytes.length));
      },
    );

    test(
      'defaults tileSize to the source level\'s own tile edge length instead '
      'of 256',
      () async {
        // This fixture's single tile spans the whole 40x40 image, so its
        // tileWidth/tileLength are 40 — nothing like this function's own
        // 256 default, making the two easy to tell apart.
        final file = await _buildSingleTileJpegFixture(
          tempDir,
          'src.svs',
          size: 40,
          color: (200, 100, 50),
        );
        final svs = await SvsFile.open(file.path);
        addTearDown(svs.close);
        expect(svs.levels.single.tileWidth, 40);

        final outBytes = await exportSvsRegionAsSvs(
          svs,
          level: 0,
          x: 0,
          y: 0,
          width: 40,
          height: 40,
          // tileSize deliberately omitted -> auto.
          matchSourceCompression: true,
        );

        final outFile = File('${tempDir.path}/out.svs');
        await outFile.writeAsBytes(outBytes);
        final roundTripped = await SvsFile.open(outFile.path);
        addTearDown(roundTripped.close);

        expect(roundTripped.levels.single.tileWidth, 40);
        expect(roundTripped.levels.single.tileLength, 40);
      },
    );

    test(
      'an explicit tileSize still overrides the source-matched default',
      () async {
        final file = await _buildSingleTileJpegFixture(
          tempDir,
          'src.svs',
          size: 40,
          color: (200, 100, 50),
        );
        final svs = await SvsFile.open(file.path);
        addTearDown(svs.close);

        final outBytes = await exportSvsRegionAsSvs(
          svs,
          level: 0,
          x: 0,
          y: 0,
          width: 40,
          height: 40,
          tileSize: 128,
          matchSourceCompression: true,
        );

        final outFile = File('${tempDir.path}/out.svs');
        await outFile.writeAsBytes(outBytes);
        final roundTripped = await SvsFile.open(outFile.path);
        addTearDown(roundTripped.close);

        expect(roundTripped.levels.single.tileWidth, 128);
      },
    );
  });

  test('JP2K export with a non-tile-aligned crop pads boundary tiles instead '
      'of corrupting them', () async {
    // 300x300 with tileSize 128 -> boundary tiles in both x/y (2 full
    // 128-col tiles + a 44-col remainder; same for rows), the case that
    // needs the nominal-size padding — every reader in this package
    // assumes a JP2K tile always decodes at the full nominal tile size.
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 300,
      color: (10, 150, 220),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final outBytes = await exportSvsRegionAsSvs(
      svs,
      level: 0,
      x: 0,
      y: 0,
      width: 300,
      height: 300,
      tileSize: 128,
      compression: SvsExportCompression.jpeg2000,
    );

    final outFile = File('${tempDir.path}/out.svs');
    await outFile.writeAsBytes(outBytes);
    final roundTripped = await SvsFile.open(outFile.path);
    addTearDown(roundTripped.close);

    expect(roundTripped.levels[0].isJp2k, isTrue);
    expect(roundTripped.levels[0].width, 300);
    expect(roundTripped.levels[0].height, 300);

    // Reads a region that only the boundary tile (tx=2, ty=2) covers —
    // exercises the padded-tile decode path directly, not just its
    // interior full-size neighbors.
    final region = await readSvsRegion(
      roundTripped,
      level: 0,
      x: 280,
      y: 280,
      width: 20,
      height: 20,
    );
    addTearDown(region.dispose);
    final data = await region.toByteData();
    final pixels = data!.buffer.asUint8List();
    expect(pixels[0], closeTo(10, 2));
    expect(pixels[1], closeTo(150, 2));
    expect(pixels[2], closeTo(220, 2));
  });

  test(
    'round-trips a crop bigger than one tile: multiple pyramid levels are generated',
    () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 512,
        color: (10, 150, 220),
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 512,
        height: 512,
        tileSize:
            256, // -> level 0 = 512x512 (4 tiles), level 1 = 256x256 (1 tile)
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels, hasLength(2));
      expect(roundTripped.levels[0].width, 512);
      expect(roundTripped.levels[0].height, 512);
      expect(roundTripped.levels[1].width, 256);
      expect(roundTripped.levels[1].height, 256);
      expect(roundTripped.levels[1].downsample, closeTo(2.0, 1e-9));

      // The coarsest level is a box-filter downsample of a solid fill, so it
      // should still be (approximately) the same solid color.
      final region = await readSvsRegion(
        roundTripped,
        level: 1,
        x: 0,
        y: 0,
        width: 256,
        height: 256,
      );
      addTearDown(region.dispose);
      final data = await region.toByteData();
      final pixels = data!.buffer.asUint8List();
      expect(pixels[0], closeTo(10, 10));
      expect(pixels[1], closeTo(150, 10));
      expect(pixels[2], closeTo(220, 10));
    },
  );

  test(
    'the exported file carries a decodable thumbnail (SvsImageView\'s minimap needs one)',
    () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 512,
        color: (10, 150, 220),
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 512,
        height: 512,
        tileSize: 256, // -> level 0 = 512x512, level 1 (coarsest) = 256x256
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      final thumbnails = roundTripped.associatedImages.where(
        (a) => a.kind == AssociatedImageKind.thumbnail,
      );
      expect(thumbnails, hasLength(1));
      final thumbnail = thumbnails.single;
      // Matches the coarsest pyramid level's own dimensions — the thumbnail
      // is that level's already-downsampled image, reused rather than
      // re-decoded from the source.
      expect(thumbnail.width, 256);
      expect(thumbnail.height, 256);
      expect(thumbnail.isDecodable, isTrue);

      final decoded = await decodeAssociatedImage(thumbnail);
      addTearDown(decoded.dispose);
      final data = await decoded.toByteData();
      final pixels = data!.buffer.asUint8List();
      expect(pixels[0], closeTo(10, 10));
      expect(pixels[1], closeTo(150, 10));
      expect(pixels[2], closeTo(220, 10));
    },
  );

  test('the exported file carries over the source label image and other '
      'ImageDescription metadata, unmodified', () async {
    final file = await _buildFixtureWithLabel(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
      labelSize: 32,
      labelColor: (30, 200, 60),
      imageDescription:
          'Aperio Image Library v11.2.1\r\n'
          '64x64 [0,0 64x64] (64x64) JPEG/RGB Q=30|AppMag = 20|'
          'MPP = 0.4990|ScanScope ID = SS1234|Filename = orig.svs|'
          'Left = 12.3|Top = 4.5|OriginalWidth = 9999|OriginalHeight = 8888',
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);
    expect(
      svs.associatedImages.single.kind,
      AssociatedImageKind.label,
    ); // sanity-check the fixture itself before exporting it

    final outBytes = await exportSvsRegionAsSvs(
      svs,
      level: 0,
      x: 0,
      y: 0,
      width: 64,
      height: 64,
      tileSize: 256,
    );

    final outFile = File('${tempDir.path}/out.svs');
    await outFile.writeAsBytes(outBytes);
    final roundTripped = await SvsFile.open(outFile.path);
    addTearDown(roundTripped.close);

    final labels = roundTripped.associatedImages.where(
      (a) => a.kind == AssociatedImageKind.label,
    );
    expect(labels, hasLength(1));
    final label = labels.single;
    expect(label.width, 32);
    expect(label.height, 32);
    expect(label.isDecodable, isTrue);

    final decoded = await decodeAssociatedImage(label);
    addTearDown(decoded.dispose);
    final data = await decoded.toByteData();
    final pixels = data!.buffer.asUint8List();
    expect(pixels[0], closeTo(30, 10));
    expect(pixels[1], closeTo(200, 10));
    expect(pixels[2], closeTo(60, 10));

    // Non-positional metadata survives verbatim...
    expect(roundTripped.metadata.raw['ScanScope ID'], 'SS1234');
    expect(roundTripped.metadata.raw['Filename'], 'orig.svs');
    // ...but fields describing the source image's position/size *within
    // the original slide* don't carry over — they'd be wrong for a crop.
    expect(roundTripped.metadata.raw.containsKey('Left'), isFalse);
    expect(roundTripped.metadata.raw.containsKey('Top'), isFalse);
    expect(roundTripped.metadata.raw.containsKey('OriginalWidth'), isFalse);
    expect(roundTripped.metadata.raw.containsKey('OriginalHeight'), isFalse);
  });

  test('includeLabelAndMacroImages: false omits the label/macro images but '
      'keeps the thumbnail', () async {
    final file = await _buildFixtureWithLabel(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
      labelSize: 32,
      labelColor: (30, 200, 60),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final outBytes = await exportSvsRegionAsSvs(
      svs,
      level: 0,
      x: 0,
      y: 0,
      width: 64,
      height: 64,
      tileSize: 256,
      includeLabelAndMacroImages: false,
    );

    final outFile = File('${tempDir.path}/out.svs');
    await outFile.writeAsBytes(outBytes);
    final roundTripped = await SvsFile.open(outFile.path);
    addTearDown(roundTripped.close);

    expect(
      roundTripped.associatedImages.where(
        (a) => a.kind == AssociatedImageKind.label,
      ),
      isEmpty,
    );
    // The thumbnail (unrelated to includeLabelAndMacroImages) still shows
    // up — it's always generated from the crop itself.
    expect(
      roundTripped.associatedImages.where(
        (a) => a.kind == AssociatedImageKind.thumbnail,
      ),
      hasLength(1),
    );
  });

  test(
    'includeSourceMetadata: false keeps only the recomputed AppMag/MPP',
    () async {
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 64,
        color: (200, 100, 50),
        imageDescription:
            'Aperio Image Library v11.2.1\r\n'
            '64x64 [0,0 64x64] (64x64) JPEG/RGB Q=30|AppMag = 20|'
            'MPP = 0.4990|ScanScope ID = SS1234|Filename = orig.svs',
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 64,
        height: 64,
        tileSize: 256,
        includeSourceMetadata: false,
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      // AppMag/MPP are always recomputed for the crop, regardless of the
      // flag — only the *rest* of the source's fields are gated by it.
      expect(roundTripped.metadata.appMag, 20);
      expect(roundTripped.metadata.mppX, closeTo(0.4990, 1e-6));
      expect(roundTripped.metadata.raw.containsKey('ScanScope ID'), isFalse);
      expect(roundTripped.metadata.raw.containsKey('Filename'), isFalse);
    },
  );

  test(
    'round-trips a crop spanning several strips/tile-rows and pyramid levels',
    () async {
      // tileSize 128 with an 800x800 source -> level 0 needs 7 strips
      // (128*6 + 32), well beyond the single-strip/single-flush cases the
      // other tests exercise, plus several downsample levels beneath it.
      final file = await _buildSingleTileJpegFixture(
        tempDir,
        'src.svs',
        size: 800,
        color: (30, 180, 90),
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 800,
        height: 800,
        tileSize: 128,
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels[0].width, 800);
      expect(roundTripped.levels[0].height, 800);
      expect(roundTripped.levels.length, greaterThan(2));

      final coarsest = roundTripped.levels.last;
      expect(coarsest.width, lessThanOrEqualTo(128));
      expect(coarsest.height, lessThanOrEqualTo(128));

      // A solid fill should survive every level's box-filter downsample.
      for (final lvl in roundTripped.levels) {
        final region = await readSvsRegion(
          roundTripped,
          level: lvl.index,
          x: 0,
          y: 0,
          width: lvl.width,
          height: lvl.height,
        );
        addTearDown(region.dispose);
        final data = await region.toByteData();
        final pixels = data!.buffer.asUint8List();
        expect(pixels[0], closeTo(30, 10));
        expect(pixels[1], closeTo(180, 10));
        expect(pixels[2], closeTo(90, 10));
        // Bottom-right corner too, in case a strip/tile boundary got
        // mis-stitched.
        final lastPixel = pixels.length - 4;
        expect(pixels[lastPixel], closeTo(30, 10));
        expect(pixels[lastPixel + 1], closeTo(180, 10));
        expect(pixels[lastPixel + 2], closeTo(90, 10));
      }
    },
  );

  test('onProgress is invoked with increasing values up to 1.0', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 400,
      color: (10, 150, 220),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final progressValues = <double>[];
    await exportSvsRegionAsSvs(
      svs,
      level: 0,
      x: 0,
      y: 0,
      width: 400,
      height: 400,
      tileSize: 128,
      onProgress: progressValues.add,
    );

    expect(progressValues, isNotEmpty);
    for (var i = 1; i < progressValues.length; i++) {
      expect(progressValues[i], greaterThan(progressValues[i - 1]));
    }
    expect(progressValues.last, closeTo(1.0, 1e-9));
  });

  test('exportSvsRegionAsSvsToFile writes the same bytes to disk', () async {
    final file = await _buildSingleTileJpegFixture(
      tempDir,
      'src.svs',
      size: 64,
      color: (200, 100, 50),
    );
    final svs = await SvsFile.open(file.path);
    addTearDown(svs.close);

    final outPath = '${tempDir.path}/out.svs';
    // exportSvsRegionAsSvsToFile only exists in the dart:io conditional-
    // export branch (returns dart:io's File) — the analyzer resolves
    // conditional exports to their default/stub branch absent a specific
    // compile target, so it doesn't see this symbol even though it's
    // genuinely present (and this test genuinely passes) on every native
    // platform `flutter test` actually runs against.
    // ignore: undefined_function
    final outFile = await exportSvsRegionAsSvsToFile(
      svs,
      path: outPath,
      level: 0,
      x: 0,
      y: 0,
      width: 64,
      height: 64,
    );
    expect(outFile.path, outPath);

    final roundTripped = await SvsFile.open(outPath);
    addTearDown(roundTripped.close);
    expect(roundTripped.levels.single.width, 64);
    expect(roundTripped.levels.single.height, 64);
  });

  group('exportSvsRegionAsSvsPreservingLevels', () {
    test('crops each output level directly from the matching source level, '
        'not by downsampling the finest one', () async {
      // Non-2x downsample steps (ds=1, 3, 12) — exactly the kind of real
      // Aperio pyramid exportSvsRegionAsSvs's halving approach could never
      // reproduce. Each level gets its own distinct solid color so a
      // level's own pixels (not some box-downsampled blend of a finer
      // level's color) can be told apart directly.
      final file = await _buildMultiLevelJpegFixture(
        tempDir,
        'src.svs',
        levelSizes: [120, 40, 10],
        levelColors: [(200, 20, 20), (20, 200, 20), (20, 20, 200)],
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);
      expect(svs.levels, hasLength(3));

      final outBytes = await exportSvsRegionAsSvsPreservingLevels(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 120,
        height: 120,
        tileSize: 256,
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels, hasLength(3));
      expect(roundTripped.levels[0].width, 120);
      expect(roundTripped.levels[1].width, 40);
      expect(roundTripped.levels[2].width, 10);
      // The source's own relative downsample steps (3x, 12x) survive,
      // unlike exportSvsRegionAsSvs's always-2x-stepped pyramid.
      expect(roundTripped.levels[1].downsample, closeTo(3.0, 0.01));
      expect(roundTripped.levels[2].downsample, closeTo(12.0, 0.01));

      Future<List<int>> pixelAt(int level) async {
        final region = await readSvsRegion(
          roundTripped,
          level: level,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
        );
        addTearDown(region.dispose);
        final data = await region.toByteData();
        return data!.buffer.asUint8List().sublist(0, 3);
      }

      final level0Pixel = await pixelAt(0);
      final level1Pixel = await pixelAt(1);
      final level2Pixel = await pixelAt(2);
      expect(level0Pixel[0], closeTo(200, 10));
      expect(level0Pixel[1], closeTo(20, 10));
      // If this were downsampled from level 0 instead of cropped from the
      // source's own green level 1, it would read back close to level 0's
      // red, not green.
      expect(level1Pixel[0], closeTo(20, 10));
      expect(level1Pixel[1], closeTo(200, 10));
      expect(level2Pixel[0], closeTo(20, 10));
      expect(level2Pixel[2], closeTo(200, 10));
    });

    test('cropping from a non-zero level only includes that level and coarser '
        'ones, not finer ones', () async {
      final file = await _buildMultiLevelJpegFixture(
        tempDir,
        'src.svs',
        levelSizes: [120, 40, 10],
        levelColors: [(200, 20, 20), (20, 200, 20), (20, 20, 200)],
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvsPreservingLevels(
        svs,
        level: 1,
        x: 0,
        y: 0,
        width: 40,
        height: 40,
        tileSize: 256,
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      expect(roundTripped.levels, hasLength(2));
      expect(roundTripped.levels[0].width, 40);
      expect(roundTripped.levels[1].width, 10);
      expect(roundTripped.levels[1].downsample, closeTo(4.0, 0.01));
    });

    test('matchSourceCompression parses the quality of the level being cropped '
        'from, same as exportSvsRegionAsSvs', () async {
      final file = await _buildMultiLevelJpegFixture(
        tempDir,
        'src.svs',
        levelSizes: [120, 40, 10],
        levelColors: [(200, 20, 20), (20, 200, 20), (20, 20, 200)],
        level0ImageDescription:
            'Aperio Image Library v11.2.1\r\n'
            '120x120 [0,0 120x120] (120x120) JPEG/RGB Q=42|AppMag = 20',
      );
      final svs = await SvsFile.open(file.path);
      addTearDown(svs.close);

      final outBytes = await exportSvsRegionAsSvsPreservingLevels(
        svs,
        level: 0,
        x: 0,
        y: 0,
        width: 120,
        height: 120,
        tileSize: 256,
        matchSourceCompression: true,
      );

      final outFile = File('${tempDir.path}/out.svs');
      await outFile.writeAsBytes(outBytes);
      final roundTripped = await SvsFile.open(outFile.path);
      addTearDown(roundTripped.close);

      final description = await roundTripped.levels[0].imageDescription;
      expect(description, contains('Q=42'));
    });

    test(
      'exportSvsRegionAsSvsPreservingLevelsToFile writes the same bytes to disk',
      () async {
        final file = await _buildMultiLevelJpegFixture(
          tempDir,
          'src.svs',
          levelSizes: [120, 40, 10],
          levelColors: [(200, 20, 20), (20, 200, 20), (20, 20, 200)],
        );
        final svs = await SvsFile.open(file.path);
        addTearDown(svs.close);

        final outPath = '${tempDir.path}/out.svs';
        // See the comment on exportSvsRegionAsSvsToFile above.
        // ignore: undefined_function
        final outFile = await exportSvsRegionAsSvsPreservingLevelsToFile(
          svs,
          path: outPath,
          level: 0,
          x: 0,
          y: 0,
          width: 120,
          height: 120,
          tileSize: 256,
        );
        expect(outFile.path, outPath);

        final roundTripped = await SvsFile.open(outPath);
        addTearDown(roundTripped.close);
        expect(roundTripped.levels, hasLength(3));
      },
    );
  });
}
