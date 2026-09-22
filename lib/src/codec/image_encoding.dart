import 'dart:typed_data';

import 'bmp_encoder.dart';
import 'jpeg_encoder.dart';
import 'png_encoder.dart';
import 'rgba_image.dart';
import 'tiff_encoder.dart';
import 'webp_encoder.dart';

/// Encodes [image] in the format at [formatIndex] of `SvsImageFormat` (png,
/// jpeg, bmp, tiff, webp) — by index so the web codec worker, which can't
/// import `dart:ui`-dependent code, can share this.
Uint8List encodeRgbaImage(RgbaImage image, int formatIndex, int quality) =>
    switch (formatIndex) {
      0 => encodePng(image),
      1 => JpegEncoder(quality: quality).encode(image),
      2 => encodeBmp(image),
      3 => encodeTiff(image),
      _ => encodeWebP(image),
    };
