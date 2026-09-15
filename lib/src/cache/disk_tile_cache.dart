// The dart:io implementation is the default and the web stub the exception,
// so dartdoc — which resolves the default — documents the real API on
// pub.dev instead of the stub.
export 'disk_tile_cache_io.dart'
    if (dart.library.js_interop) 'disk_tile_cache_stub.dart';
