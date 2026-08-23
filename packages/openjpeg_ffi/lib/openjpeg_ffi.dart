import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;

import 'openjpeg_ffi_bindings_generated.dart' as bindings;

/// A decoded JPEG2000 raster: [pixels] is interleaved, tightly packed,
/// `width * height * numComponents` bytes (row-major, no padding).
class Jp2kImage {
  final int width;
  final int height;
  final int numComponents;
  final Uint8List pixels;

  const Jp2kImage({required this.width, required this.height, required this.numComponents, required this.pixels});
}

/// A JPEG2000 codestream failed to decode — malformed input, an
/// unsupported codestream feature, or similar. Carries OpenJPEG's own
/// error message.
class Jp2kDecodeException implements Exception {
  final String message;

  const Jp2kDecodeException(this.message);

  @override
  String toString() => 'Jp2kDecodeException: $message';
}

/// Decodes a raw J2K codestream (starts `FF4F` = SOC marker — *not* the
/// box-structured `.jp2` file format) from [bytes].
///
/// [reducedResolutionFactor] discards the N highest-resolution wavelet
/// levels during decode (0 = full resolution) — useful for a caller that
/// only needs a coarse preview and wants to skip most of the decode cost.
///
/// Synchronous and blocking: FFI calls occupy the calling isolate for
/// their full duration. Unlike `dart:ui`'s image codecs (which must run on
/// the main isolate — see flutter/flutter#109701), this has no such
/// restriction, so call it from a background isolate to keep the decode
/// off the UI thread.
///
/// Throws [Jp2kDecodeException] if decoding fails.
Jp2kImage decodeJ2k(Uint8List bytes, {int reducedResolutionFactor = 0}) {
  final buffer = pkg_ffi.malloc<ffi.Uint8>(bytes.length);
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);

    final resultPtr = bindings.jp2k_decode(buffer, bytes.length, reducedResolutionFactor);
    if (resultPtr == ffi.nullptr) {
      throw const Jp2kDecodeException('jp2k_decode returned null (out of memory allocating the result)');
    }
    try {
      final result = resultPtr.ref;
      if (result.error != ffi.nullptr) {
        throw Jp2kDecodeException(result.error.cast<pkg_ffi.Utf8>().toDartString());
      }
      final pixelCount = result.width * result.height * result.num_components;
      return Jp2kImage(
        width: result.width,
        height: result.height,
        numComponents: result.num_components,
        pixels: Uint8List.fromList(result.pixels.asTypedList(pixelCount)),
      );
    } finally {
      bindings.jp2k_free_result(resultPtr);
    }
  } finally {
    pkg_ffi.malloc.free(buffer);
  }
}
