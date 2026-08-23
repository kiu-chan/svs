import 'dart:typed_data';

/// Expands tightly-packed RGB (3 samples/pixel) or RGBA (4 samples/pixel)
/// raster samples to tightly-packed RGBA8888 — the layout `dart:ui`'s
/// `decodeImageFromPixels` expects. RGB gets an opaque alpha byte appended
/// per pixel; RGBA already matches and is returned as-is.
Uint8List expandRgbToRgba(
  Uint8List samples, {
  required int width,
  required int height,
  required int samplesPerPixel,
}) {
  if (samplesPerPixel == 4) return samples;

  final pixelCount = width * height;
  final rgba = Uint8List(pixelCount * 4);
  var src = 0;
  var dst = 0;
  for (var p = 0; p < pixelCount; p++) {
    rgba[dst] = samples[src];
    rgba[dst + 1] = samples[src + 1];
    rgba[dst + 2] = samples[src + 2];
    rgba[dst + 3] = 0xFF;
    src += 3;
    dst += 4;
  }
  return rgba;
}
