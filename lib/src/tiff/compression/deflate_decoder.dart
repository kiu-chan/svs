import 'dart:io';
import 'dart:typed_data';

/// Decodes a TIFF `Compression=8`/`32946` (Deflate / "Adobe Deflate") byte
/// stream. Both tag values denote a standard zlib-wrapped deflate stream in
/// virtually all real-world files, so both are handled identically here.
///
/// Uses `dart:io`'s built-in zlib support — part of the Dart SDK, not a
/// plugin or FFI dependency — rather than a hand-written inflate.
Uint8List decodeTiffDeflate(Uint8List data) {
  return Uint8List.fromList(ZLibDecoder().convert(data));
}
