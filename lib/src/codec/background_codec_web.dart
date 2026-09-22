import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import '../render/image_adjustments.dart';
import '../web/codec_worker_pool.dart';
import '../web/codec_worker_protocol.dart';
import 'image_encoding.dart';
import 'jpeg2000/j2k_decoder.dart';
import 'jpeg2000/j2k_encoder.dart';
import 'rgba_image.dart';

/// Decodes a JPEG2000 codestream on a Web Worker, or on the calling thread
/// if the page can't run one.
Future<J2kImage> decodeJ2kInBackground(
  Uint8List bytes, {
  int reducedResolutionFactor = 0,
}) async {
  final transfer = <JSAny>[];
  final request = JSObject()
    ..[bytesField] = transferableCopy(bytes, transfer)
    ..[reduceField] = reducedResolutionFactor.toJS;
  final reply = await requestOrNull(opDecodeJ2k, request, transfer);
  if (reply == null) {
    return decodeJ2k(bytes, reducedResolutionFactor: reducedResolutionFactor);
  }
  return J2kImage(
    width: (reply[widthField] as JSNumber).toDartInt,
    height: (reply[heightField] as JSNumber).toDartInt,
    numComponents: (reply[componentsField] as JSNumber).toDartInt,
    pixels: (reply[pixelsField] as JSUint8Array).toDart,
  );
}

/// How many [decodeJ2kInBackground] calls are worth having in flight at
/// once: enough to keep every worker busy.
int get backgroundDecodeSlots => math.max(1, 2 * CodecWorkerPool.instance.size);

/// Applies [adjustments] to [pixels] (RGBA) and encodes them as the
/// `SvsImageFormat` at [formatIndex] on a Web Worker — or on the calling
/// thread if the page can't run one. The adjustment itself runs here.
Future<Uint8List> encodeImageInBackground(
  Uint8List pixels,
  int width,
  int height,
  int formatIndex,
  int quality,
  SvsImageAdjustments adjustments,
) async {
  adjustments.applyToRgba(pixels);
  final transfer = <JSAny>[];
  final request = JSObject()
    ..[pixelsField] = transferableCopy(pixels, transfer)
    ..[widthField] = width.toJS
    ..[heightField] = height.toJS
    ..[formatField] = formatIndex.toJS
    ..[qualityField] = quality.toJS;
  final reply = await requestOrNull(opEncodeImage, request, transfer);
  if (reply == null) {
    return encodeRgbaImage(
      RgbaImage(width, height, pixels),
      formatIndex,
      quality,
    );
  }
  return (reply[bytesField] as JSUint8Array).toDart;
}

/// Runs [request] on a worker: its reply, or null if no worker could take
/// it (the caller then does the work itself). Rethrows the worker's own
/// failure as the exception it was.
Future<JSObject?> requestOrNull(
  String op,
  JSObject request,
  List<JSAny> transfer,
) async {
  final JSObject reply;
  try {
    reply = await CodecWorkerPool.instance.request(op, request, transfer);
  } on CodecWorkerUnavailable {
    return null;
  }
  final error = reply[errorField];
  if (error == null) return reply;
  final message = (error as JSString).toDart;
  throw switch ((reply[errorKindField] as JSString).toDart) {
    errorKindJ2kDecode => J2kDecodeException(message),
    errorKindJ2kEncode => J2kEncodeException(message),
    errorKindArgument => ArgumentError(message),
    _ => StateError(message),
  };
}
