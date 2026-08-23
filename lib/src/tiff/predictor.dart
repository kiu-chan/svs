import 'dart:typed_data';

/// Undoes TIFF `Predictor=2` (horizontal differencing) in place: each
/// component sample was stored as its difference from the same component
/// one pixel to its left, resetting at the start of every row.
void undoHorizontalPredictor(Uint8List samples, {required int width, required int height, required int samplesPerPixel}) {
  final rowBytes = width * samplesPerPixel;
  for (var row = 0; row < height; row++) {
    final rowStart = row * rowBytes;
    for (var i = samplesPerPixel; i < rowBytes; i++) {
      samples[rowStart + i] = (samples[rowStart + i] + samples[rowStart + i - samplesPerPixel]) & 0xFF;
    }
  }
}
