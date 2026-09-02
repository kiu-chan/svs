// A terminal entry point for `rebuildSvsPyramid`/`rebuildSvsPyramidToFile`/
// `rebuildSvsPyramidInPlace` — this package's tile decoding goes through
// `dart:ui` (`region_decoder.dart`'s `ui.instantiateImageCodec`), which only
// exists inside a Flutter engine, so it can't run under a plain `dart run`.
// `flutter test`'s headless "flutter_tester" engine has a working `dart:ui`,
// so this file is written as a single `test()` (which also means the
// process's exit code — 0 on success, 1 on a thrown error — comes for free
// from the test framework, useful for scripting/CI) and driven with
// environment variables instead of `main(List<String> args)`, since
// `flutter test` doesn't forward arbitrary CLI args to the file it runs.
//
// Usage (run from the package root, or point --package-root/-C at it):
//
//   SVS_PATH=/path/to/slide.svs flutter test tool/rebuild_pyramid.dart
//
// Required:
//   SVS_PATH             Path to the source .svs file.
//
// Output — pick one (defaults to a new file next to the source):
//   SVS_MODE              "new-file" (default) or "in-place".
//   SVS_OUTPUT             new-file mode only: output path. Defaults to
//                          "<SVS_PATH without .svs>.rebuilt.svs".
//
// Optional:
//   SVS_LEVEL_COUNT        Target pyramid level count. Omit for auto (the
//                          smoothest possible 2x-halved cascade — increases
//                          the level count for a source with few/uneven
//                          levels). A smaller explicit value decreases it.
//   SVS_TILE_SIZE           Tile edge length. Omit to keep the source's own
//                          (matchSourceCompression's default here).
//   SVS_EFFORT              "low", "balanced" (default), or "high" — RAM/CPU
//                          vs. UI-smoothness tradeoff; irrelevant here (no
//                          UI to protect) but "low" also means less CPU
//                          burst on a shared machine.
//   SVS_QUALITY             JPEG quality 1-100 (default 90). Only applies
//                          when SVS_MATCH_SOURCE_COMPRESSION=false.
//   SVS_COMPRESSION         "jpeg" (default) or "jpeg2000". Only applies
//                          when SVS_MATCH_SOURCE_COMPRESSION=false.
//   SVS_JP2K_RATIO          JPEG2000 target ratio, e.g. "20" (default 0 =
//                          lossless). Only applies when compression is
//                          jpeg2000 and SVS_MATCH_SOURCE_COMPRESSION=false.
//   SVS_MATCH_SOURCE_COMPRESSION
//                          "true" (default) or "false" — true keeps the
//                          rebuilt file visually/size-equivalent to the
//                          source instead of re-encoding at the
//                          SVS_QUALITY/SVS_COMPRESSION settings above.
//
// Examples:
//
//   # Auto-increase levels for smoother zoom, new file next to the source.
//   SVS_PATH=slide.svs flutter test tool/rebuild_pyramid.dart
//
//   # Decrease to 4 levels, overwriting the source file itself.
//   SVS_PATH=slide.svs SVS_LEVEL_COUNT=4 SVS_MODE=in-place \
//     flutter test tool/rebuild_pyramid.dart
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/svs.dart';

void main() {
  test('rebuild pyramid', () async {
    final path = _requireEnv('SVS_PATH');
    if (!File(path).existsSync()) {
      throw ArgumentError('SVS_PATH does not exist: $path');
    }

    final mode = Platform.environment['SVS_MODE'] ?? 'new-file';
    if (mode != 'new-file' && mode != 'in-place') {
      throw ArgumentError('SVS_MODE must be "new-file" or "in-place", got: $mode');
    }

    final levelCount = _optionalInt('SVS_LEVEL_COUNT');
    final tileSize = _optionalInt('SVS_TILE_SIZE');
    final quality = _optionalInt('SVS_QUALITY') ?? 90;
    final jp2kRatio = _optionalDouble('SVS_JP2K_RATIO') ?? 0;
    final matchSourceCompression = _optionalBool(
      'SVS_MATCH_SOURCE_COMPRESSION',
    ) ?? true;
    final compression = switch (Platform.environment['SVS_COMPRESSION']) {
      null || 'jpeg' => SvsExportCompression.jpeg,
      'jpeg2000' => SvsExportCompression.jpeg2000,
      final other => throw ArgumentError(
        'SVS_COMPRESSION must be "jpeg" or "jpeg2000", got: $other',
      ),
    };
    final effort = switch (Platform.environment['SVS_EFFORT']) {
      null || 'balanced' => SvsPyramidRebuildEffort.balanced,
      'low' => SvsPyramidRebuildEffort.low,
      'high' => SvsPyramidRebuildEffort.high,
      final other => throw ArgumentError(
        'SVS_EFFORT must be "low", "balanced", or "high", got: $other',
      ),
    };

    // ignore: avoid_print
    print('Opening $path ...');
    var svsFile = await SvsFile.open(path);
    // ignore: avoid_print
    print(
      'Source: ${svsFile.levels.length} level(s), '
      '${svsFile.levels.map((l) => '${l.width}x${l.height}').join(' / ')}',
    );

    var lastReported = -1;
    void onProgress(double p) {
      final percent = (p * 100).floor();
      if (percent == lastReported) return;
      lastReported = percent;
      // ignore: avoid_print
      print('  $percent%');
    }

    if (mode == 'in-place') {
      // ignore: avoid_print
      print('Rebuilding in place ...');
      // rebuildSvsPyramidInPlace only exists in the dart:io conditional-
      // export branch — see the comment on rebuildSvsPyramidToFile below.
      // ignore: undefined_function
      svsFile = await rebuildSvsPyramidInPlace(
        svsFile,
        levelCount: levelCount,
        tileSize: tileSize,
        quality: quality,
        compression: compression,
        jp2kCompressionRatio: jp2kRatio,
        matchSourceCompression: matchSourceCompression,
        effort: effort,
        onProgress: onProgress,
      );
      // ignore: avoid_print
      print('Done: $path now has ${svsFile.levels.length} level(s).');
    } else {
      final output =
          Platform.environment['SVS_OUTPUT'] ??
          '${_withoutSvsExtension(path)}.rebuilt.svs';
      // ignore: avoid_print
      print('Rebuilding to $output ...');
      // rebuildSvsPyramidToFile only exists in the dart:io conditional-
      // export branch — the analyzer resolves conditional exports to their
      // stub branch absent a specific compile target, so it doesn't see
      // this symbol even though it's genuinely present when this script is
      // actually run (via `flutter test`, on a native platform).
      // ignore: undefined_function
      await rebuildSvsPyramidToFile(
        svsFile,
        path: output,
        levelCount: levelCount,
        tileSize: tileSize,
        quality: quality,
        compression: compression,
        jp2kCompressionRatio: jp2kRatio,
        matchSourceCompression: matchSourceCompression,
        effort: effort,
        onProgress: onProgress,
      );
      await svsFile.close();
      // ignore: avoid_print
      print('Done: wrote $output.');
    }
  });
}

String _requireEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw ArgumentError(
      '$name is required. See the usage comment at the top of '
      'tool/rebuild_pyramid.dart.',
    );
  }
  return value;
}

int? _optionalInt(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) return null;
  final parsed = int.tryParse(value);
  if (parsed == null) throw ArgumentError('$name must be an integer, got: $value');
  return parsed;
}

double? _optionalDouble(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) return null;
  final parsed = double.tryParse(value);
  if (parsed == null) throw ArgumentError('$name must be a number, got: $value');
  return parsed;
}

bool? _optionalBool(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) return null;
  if (value == 'true') return true;
  if (value == 'false') return false;
  throw ArgumentError('$name must be "true" or "false", got: $value');
}

String _withoutSvsExtension(String path) =>
    path.toLowerCase().endsWith('.svs')
    ? path.substring(0, path.length - 4)
    : path;
