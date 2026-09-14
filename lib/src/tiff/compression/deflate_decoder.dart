import 'dart:typed_data';

import '../../codec/zlib.dart';

/// Decodes a TIFF `Compression=8`/`32946` (Deflate / "Adobe Deflate") byte
/// stream. Both tag values denote a standard zlib-wrapped deflate stream in
/// virtually all real-world files, so both are handled identically here.
///
/// Uses `dart:io`'s native zlib where available and this package's own
/// pure-Dart inflater on the web (see `codec/zlib.dart`), so this works
/// everywhere.
Uint8List decodeTiffDeflate(Uint8List data) {
  return zlibDecode(data);
}
