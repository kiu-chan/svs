import 'dart:io';

import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final vendorDir = Directory.fromUri(input.packageRoot.resolve('src/vendor/openjp2/'));
    final vendorSources = vendorDir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.c'))
        .map((name) => 'src/vendor/openjp2/$name')
        .toList();

    final cbuilder = CBuilder.library(
      name: packageName,
      assetName: '${packageName}_bindings_generated.dart',
      sources: ['src/$packageName.c', ...vendorSources],
      includes: ['src/vendor/openjp2/'],
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = .ALL
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
