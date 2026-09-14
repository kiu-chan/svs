import 'dart:typed_data';

import 'deflate.dart';
import 'inflate.dart';

/// Decompresses a zlib-wrapped deflate stream.
Uint8List zlibDecode(Uint8List data) => inflateZlib(data);

/// Compresses [data] into a zlib-wrapped deflate stream.
Uint8List zlibEncode(Uint8List data) => deflateZlib(data);
