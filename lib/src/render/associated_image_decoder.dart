import 'dart:ui' as ui;

import '../errors.dart';
import '../svs/svs_file.dart';

/// Decodes [image] to a single composited [ui.Image] spanning its full
/// dimensions.
///
/// Associated images (thumbnail/label/macro) are stored as one or more
/// independent JPEG frames — each strip has its own JPEG header pair
/// declaring only that strip's own height — rather than one contiguous
/// JPEG stream covering the whole image. So each strip is decoded on its
/// own and painted into place at its row offset; concatenating their
/// compressed bytes does not produce a valid taller JPEG.
///
/// Must run on the main isolate, like any other `dart:ui` decode.
Future<ui.Image> decodeAssociatedImage(SvsAssociatedImage image) async {
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
