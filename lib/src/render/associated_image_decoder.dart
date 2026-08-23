import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../errors.dart';
import '../svs/aperio_tags.dart';
import '../svs/svs_file.dart';

/// Decodes [image] to a single composited [ui.Image] spanning its full
/// dimensions.
///
/// Associated images (thumbnail/label/macro) are stored as one or more
/// independent strips rather than one contiguous stream covering the whole
/// image — each JPEG strip has its own JPEG header pair declaring only that
/// strip's own height, and each raw-raster (LZW/PackBits/Deflate/none)
/// strip is an independently-compressed band. So each strip is decoded on
/// its own and placed at its row offset; concatenating their compressed
/// bytes does not produce a valid taller image.
///
/// Throws [SvsUnsupportedCompressionError] if [SvsAssociatedImage.isDecodable]
/// is false — check that first to avoid the exception.
///
/// Must run on the main isolate, like any other `dart:ui` decode.
Future<ui.Image> decodeAssociatedImage(SvsAssociatedImage image) async {
  if (!image.isDecodable) {
    throw SvsUnsupportedCompressionError(
      image.compression,
      'Associated image (IFD ${image.ifdIndex}, ${image.kind}) is not decodable — check isDecodable first',
    );
  }
  return image.isJpeg ? _decodeJpegStrips(image) : _decodeRawRasterStrips(image);
}

Future<ui.Image> _decodeJpegStrips(SvsAssociatedImage image) async {
  final stripCount = await image.stripCount;
  final rowsPerStrip = await image.rowsPerStrip;
  // Aperio writes these JPEG strips with TIFF PhotometricInterpretation=RGB
  // — i.e. literal RGB samples, no YCbCr transform. `dart:ui`'s decoder has
  // no visibility into that TIFF-level tag (it's outside the JPEG stream
  // itself), so it always assumes YCbCr and applies an unwanted conversion.
  // _undoSpuriousYCbCr reverses exactly that.
  final needsRgbFix = image.photometricInterpretation == ApPhotometric.rgb;
  final pixels = Uint8List(image.width * image.height * 4);
  var decodedAny = false;

  for (var i = 0; i < stripCount; i++) {
    final bytes = await image.readStripJpegBytes(i);
    if (bytes.isEmpty) continue;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final stripRgba = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      if (stripRgba == null) continue;

      final stripBytes = stripRgba.buffer.asUint8List(stripRgba.offsetInBytes, stripRgba.lengthInBytes);
      if (needsRgbFix) _undoSpuriousYCbCr(stripBytes);
      final byteOffset = i * rowsPerStrip * image.width * 4;
      pixels.setRange(byteOffset, byteOffset + stripBytes.length, stripBytes);
      decodedAny = true;
    } catch (_) {
      // Leave this band blank rather than letting one corrupt strip sink
      // the whole preview.
    }
  }

  if (!decodedAny) {
    throw SvsFormatException('Associated image (IFD ${image.ifdIndex}, ${image.kind}) has no decodable strips');
  }

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, image.width, image.height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// Inverts the JPEG decoder's spurious RGB->YCbCr->RGB round trip in place
/// on tightly-packed RGBA8888 bytes (alpha untouched). Re-running the
/// forward RGB->YCbCr formula on the wrongly-decoded output is exactly the
/// decoder's YCbCr->RGB step's inverse, so it recovers the true original
/// samples (the formula's Y/Cb/Cr outputs land back on the true R/G/B).
void _undoSpuriousYCbCr(Uint8List rgba) {
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

Future<ui.Image> _decodeRawRasterStrips(SvsAssociatedImage image) async {
  final stripCount = await image.stripCount;
  final rowsPerStrip = await image.rowsPerStrip;
  final pixels = Uint8List(image.width * image.height * 4);
  var decodedAny = false;

  for (var i = 0; i < stripCount; i++) {
    final rgba = await image.readStripRgba(i);
    if (rgba.isEmpty) continue;
    final byteOffset = i * rowsPerStrip * image.width * 4;
    pixels.setRange(byteOffset, byteOffset + rgba.length, rgba);
    decodedAny = true;
  }

  if (!decodedAny) {
    throw SvsFormatException('Associated image (IFD ${image.ifdIndex}, ${image.kind}) has no decodable strips');
  }

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, image.width, image.height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}
