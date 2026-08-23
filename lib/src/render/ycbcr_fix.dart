import 'dart:typed_data';

/// Inverts a JPEG decoder's spurious RGB->YCbCr->RGB round trip in place on
/// tightly-packed RGBA8888 bytes (alpha untouched).
///
/// Aperio writes its JPEG-compressed streams (associated images and, in some
/// files, pyramid tiles too) with TIFF `PhotometricInterpretation=RGB` —
/// i.e. literal RGB samples, no YCbCr transform applied at encode time. But
/// `dart:ui`'s decoder has no visibility into that TIFF-level tag (it lives
/// outside the JPEG stream itself), so it always assumes YCbCr and applies
/// an unwanted conversion. Re-running the forward RGB->YCbCr formula on the
/// wrongly-decoded output is exactly that step's inverse, so it recovers
/// the true original samples (the formula's Y/Cb/Cr outputs land back on
/// the true R/G/B).
void undoSpuriousYCbCr(Uint8List rgba) {
  for (var i = 0; i < rgba.length; i += 4) {
    final r = rgba[i].toDouble();
    final g = rgba[i + 1].toDouble();
    final b = rgba[i + 2].toDouble();
    final y = 0.299 * r + 0.587 * g + 0.114 * b;
    final cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128;
    final cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 128;
    rgba[i] = y.clamp(0, 255).round();
    rgba[i + 1] = cb.clamp(0, 255).round();
    rgba[i + 2] = cr.clamp(0, 255).round();
  }
}
