/// Web-only additions to `package:svs`, for working with slides larger than
/// memory: [BlobByteSource] opens a slide straight from a browser `File`,
/// and [FileSystemWritableByteSink] streams an export into one.
///
/// This library needs `dart:js_interop`, so only import it from code that
/// is compiled for the web — behind a conditional import
/// (`if (dart.library.js_interop)`) in an app that also targets other
/// platforms.
library;

export 'src/io/blob_byte_source.dart';
export 'src/io/file_system_writable_byte_sink.dart';
