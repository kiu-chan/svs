import 'dart:isolate';
import 'dart:typed_data';

import '../render/image_adjustments.dart';
import 'image_encoding.dart';
import 'jpeg2000/j2k_decoder.dart';
import 'rgba_image.dart';

/// Decodes a JPEG2000 codestream on the calling isolate — natively the
/// viewer's tiles already arrive on a worker isolate.
Future<J2kImage> decodeJ2kInBackground(
  Uint8List bytes, {
  int reducedResolutionFactor = 0,
}) async => decodeJ2k(bytes, reducedResolutionFactor: reducedResolutionFactor);

/// How many [decodeJ2kInBackground] calls are worth having in flight at
/// once from one caller: natively they run in place, one at a time.
int get backgroundDecodeSlots => 1;

/// Applies [adjustments] to [pixels] (RGBA) and encodes them as the
/// `SvsImageFormat` at [formatIndex], on a background isolate.
Future<Uint8List> encodeImageInBackground(
  Uint8List pixels,
  int width,
  int height,
  int formatIndex,
  int quality,
  SvsImageAdjustments adjustments,
) => Isolate.run(() {
  adjustments.applyToRgba(pixels);
  return encodeRgbaImage(
    RgbaImage(width, height, pixels),
    formatIndex,
    quality,
  );
});
