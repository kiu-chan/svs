import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Decodes a TIFF `Compression=8`/`32946` (Deflate / "Adobe Deflate") byte
/// stream. Both tag values denote a standard zlib-wrapped deflate stream in
/// virtually all real-world files, so both are handled identically here.
///
/// Uses `package:archive`'s `ZLibDecoder`, which dispatches to the native
/// zlib codec on `dart:io` platforms and a pure-Dart implementation on the
/// web — so this works everywhere without a platform split of its own.
Uint8List decodeTiffDeflate(Uint8List data) {
  return ZLibDecoder().decodeBytes(data);
}
