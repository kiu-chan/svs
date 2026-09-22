/// Web-only additions to `package:svs`: [BlobByteSource], for opening a
/// slide straight from a browser `File` without loading it into memory.
///
/// This library needs `dart:js_interop`, so only import it from code that
/// is compiled for the web — behind a conditional import
/// (`if (dart.library.js_interop)`) in an app that also targets other
/// platforms.
library;

export 'src/io/blob_byte_source.dart';
