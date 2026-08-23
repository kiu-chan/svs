import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../errors.dart';
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

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  var decodedAny = false;

  for (var i = 0; i < stripCount; i++) {
    final bytes = await image.readStripJpegBytes(i);
    if (bytes.isEmpty) continue;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      canvas.drawImage(frame.image, ui.Offset(0, (i * rowsPerStrip).toDouble()), ui.Paint());
      frame.image.dispose();
      decodedAny = true;
    } catch (_) {
      // Leave this band blank rather than letting one corrupt strip sink
      // the whole preview.
    }
  }

  if (!decodedAny) {
    throw SvsFormatException('Associated image (IFD ${image.ifdIndex}, ${image.kind}) has no decodable strips');
  }

  final picture = recorder.endRecording();
  try {
    return await picture.toImage(image.width, image.height);
  } finally {
    picture.dispose();
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
