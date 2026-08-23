// Manual, opt-in integration test against a real Aperio JPEG2000-compressed
// slide (the well-known CMU-1-JP2K-33005 sample). Not a synthetic TIFF like
// the rest of test/ — exercises real openjpeg_ffi decode + region stitching
// + format export end to end. Skips itself (does not fail) if the fixture
// file isn't present on this machine, since it isn't checked into this repo.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:svs/svs.dart';

const _samplePath =
    '/Users/khanh/Documents/code/mobile/svs_example/sample_data/CMU-1-JP2K-33005.svs';

void main() {
  final hasFixture = File(_samplePath).existsSync();

  test(
    'readSvsRegion / exportSvs* work against a real JP2K slide',
    () async {
      final svs = await SvsFile.open(_samplePath);
      addTearDown(svs.close);

      // ignore: avoid_print
      print(
        'levels: ${svs.levels.map((l) => '${l.width}x${l.height} (ds=${l.downsample}, jp2k=${l.isJp2k})').toList()}',
      );
      // ignore: avoid_print
      print('appMag=${svs.metadata.appMag} mppX=${svs.metadata.mppX}');
      // ignore: avoid_print
      print(
        'associated images: ${svs.associatedImages.map((a) => '${a.kind} ${a.width}x${a.height} decodable=${a.isDecodable}').toList()}',
      );

      expect(svs.levels, isNotEmpty);
      expect(svs.levels.first.isJp2k, isTrue);

      // Crop a real region from level 0, well inside the slide bounds.
      final region = await readSvsRegion(
        svs,
        level: 0,
        x: 5000,
        y: 5000,
        width: 512,
        height: 512,
      );
      expect(region.width, 512);
      expect(region.height, 512);
      region.dispose();

      // Export that same region to every supported format.
      for (final format in SvsImageFormat.values) {
        final bytes = await exportSvsRegion(
          svs,
          level: 0,
          x: 5000,
          y: 5000,
          width: 512,
          height: 512,
          format: format,
        );
        expect(bytes, isNotEmpty);
        // ignore: avoid_print
        print('exportSvsRegion($format): ${bytes.length} bytes');

        final outPath =
            '/private/tmp/claude-501/-Users-khanh-Documents-code-mobile-svs/97f51c42-75c6-4807-957e-fda291727ee5/scratchpad/export_out/region.${format.name}';
        await File(outPath).writeAsBytes(bytes);
      }

      // Export the coarsest pyramid level whole (should be small enough to
      // stay under the default maxPixels guard).
      final coarsestLevel = svs.levels.length - 1;
      final levelBytes = await exportSvsLevel(
        svs,
        level: coarsestLevel,
        format: SvsImageFormat.png,
      );
      expect(levelBytes, isNotEmpty);
      final decodedLevel = img.decodePng(levelBytes)!;
      expect(decodedLevel.width, svs.levels[coarsestLevel].width);
      expect(decodedLevel.height, svs.levels[coarsestLevel].height);
      // ignore: avoid_print
      print(
        'exportSvsLevel($coarsestLevel, png): ${levelBytes.length} bytes, '
        '${decodedLevel.width}x${decodedLevel.height}',
      );

      // Export a decodable associated image (thumbnail), if there is one.
      final thumbnail = svs.associatedImages
          .where(
            (a) => a.kind == AssociatedImageKind.thumbnail && a.isDecodable,
          )
          .firstOrNull;
      if (thumbnail != null) {
        final thumbBytes = await exportAssociatedImage(
          thumbnail,
          format: SvsImageFormat.png,
        );
        expect(thumbBytes, isNotEmpty);
        // ignore: avoid_print
        print(
          'exportAssociatedImage(thumbnail, png): ${thumbBytes.length} bytes',
        );
      }

      // Crop a real region and re-export it as a brand new pyramidal .svs,
      // then reopen *that* file and confirm it decodes back to (about) the
      // same pixels — the strongest end-to-end proof the writer's output is
      // a genuinely valid, self-consistent .svs, not just well-formed TIFF.
      final pyramidBytes = await exportSvsRegionAsSvs(
        svs,
        level: 0,
        x: 5000,
        y: 5000,
        width: 600,
        height: 400,
        tileSize: 256,
      );
      expect(pyramidBytes, isNotEmpty);
      // ignore: avoid_print
      print('exportSvsRegionAsSvs: ${pyramidBytes.length} bytes');

      final pyramidPath =
          '${Directory.systemTemp.path}/svs_manual_test_cropped_pyramid.svs';
      await File(pyramidPath).writeAsBytes(pyramidBytes);
      addTearDown(() => File(pyramidPath).delete());

      final reopened = await SvsFile.open(pyramidPath);
      addTearDown(reopened.close);
      expect(reopened.levels.first.width, 600);
      expect(reopened.levels.first.height, 400);
      // ignore: avoid_print
      print(
        'exportSvsRegionAsSvs reopened: '
        '${reopened.levels.map((l) => '${l.width}x${l.height}').toList()}',
      );

      final originalRegion = await readSvsRegion(
        svs,
        level: 0,
        x: 5000,
        y: 5000,
        width: 600,
        height: 400,
      );
      final reopenedRegion = await readSvsRegion(
        reopened,
        level: 0,
        x: 0,
        y: 0,
        width: 600,
        height: 400,
      );
      final originalData = await originalRegion.toByteData();
      final reopenedData = await reopenedRegion.toByteData();
      originalRegion.dispose();
      reopenedRegion.dispose();
      final originalPixels = originalData!.buffer.asUint8List();
      final reopenedPixels = reopenedData!.buffer.asUint8List();
      // Center pixel only — JPEG re-compression means this isn't an exact
      // match, but it should be close.
      final centerIndex =
          ((200 * 600 + 300) * 4); // row 200, col 300, of 600x400
      for (var c = 0; c < 3; c++) {
        expect(
          reopenedPixels[centerIndex + c],
          closeTo(originalPixels[centerIndex + c], 20),
        );
      }
    },
    skip: hasFixture ? false : 'sample file not present on this machine',
  );
}
