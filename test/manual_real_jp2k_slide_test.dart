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
    },
    skip: hasFixture ? false : 'sample file not present on this machine',
  );
}
