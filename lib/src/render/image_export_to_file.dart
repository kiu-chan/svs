// The dart:io implementation is the default and the web stub the exception,
// so dartdoc — which resolves the default — documents these functions on
// pub.dev instead of the stub, which doesn't declare them at all.
export 'image_export_to_file_io.dart'
    if (dart.library.js_interop) 'image_export_to_file_stub.dart';
