import 'dart:io' show zlib;
import 'dart:typed_data';

/// Decompresses a zlib-wrapped deflate stream.
Uint8List zlibDecode(Uint8List data) => _asBytes(zlib.decode(data));

/// Compresses [data] into a zlib-wrapped deflate stream.
Uint8List zlibEncode(Uint8List data) => _asBytes(zlib.encode(data));

Uint8List _asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
