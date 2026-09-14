// zlib (RFC 1950) streams: native platforms use `dart:io`'s built-in zlib;
// the web, which has no `dart:io`, uses this package's pure-Dart
// `inflate.dart`/`deflate.dart`.
export 'zlib_web.dart' if (dart.library.io) 'zlib_io.dart';
