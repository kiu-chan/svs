// The web codec worker's JavaScript is generated
// (tool/build_codec_worker.dart) and checked in, so it can fall behind the
// Dart it was compiled from. This fails when it has.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/web/codec_worker_js.g.dart';

import 'helpers/source_hash.dart';

const _rebuild = 'run `dart run tool/build_codec_worker.dart`';

void main() {
  test('the embedded worker was built from the current sources', () {
    expect(
      sourceHash(codecWorkerSources),
      codecWorkerSourceHash,
      reason: 'a worker source changed since the worker was built: $_rebuild',
    );
  });

  test('the worker imports nothing outside its recorded sources', () {
    final sources = codecWorkerSources.toSet();
    final import = RegExp(r"""^(?:import|export) '([^']+)'""", multiLine: true);
    for (final path in codecWorkerSources) {
      for (final match in import.allMatches(File(path).readAsStringSync())) {
        final target = match.group(1)!;
        if (target.startsWith('dart:')) continue;
        final resolved = target.startsWith('package:svs/')
            ? 'lib/${target.substring('package:svs/'.length)}'
            : File(path).parent.uri.resolve(target).toFilePath();
        final relative = resolved.startsWith(Directory.current.path)
            ? resolved.substring(Directory.current.path.length + 1)
            : resolved;
        // Conditional imports list alternatives the web build won't take.
        if (relative.endsWith('_io.dart')) continue;
        expect(
          sources,
          contains(relative),
          reason: '$path imports $relative: $_rebuild',
        );
      }
    }
  });
}
