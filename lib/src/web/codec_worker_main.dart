// The web codec worker: a standalone program, compiled by
// tool/build_codec_worker.dart with dart2js into the JavaScript
// codec_worker_js.g.dart embeds, that decodes and encodes on a Web Worker
// so the page's main thread doesn't. Imports only pure-Dart code — no
// dart:ui, which workers don't have.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../codec/image_encoding.dart';
import '../codec/jpeg2000/j2k_decoder.dart';
import '../codec/jpeg2000/j2k_encoder.dart';
import '../codec/rgba_image.dart';
import '../render/band_tile_encoder.dart';
import 'codec_worker_protocol.dart';

extension type _Scope._(JSObject _) implements JSObject {
  external set onmessage(JSFunction handler);
  external void postMessage(JSAny? message, JSArray<JSAny> transfer);
}

extension type _MessageEvent._(JSObject _) implements JSObject {
  external JSObject get data;
}

_Scope get _self => globalContext as _Scope;

void main() {
  _self.onmessage = ((_MessageEvent event) => _handle(event.data)).toJS;
}

int _int(JSObject m, String key) => (m[key] as JSNumber).toDartInt;

Uint8List _bytes(JSObject m, String key) => (m[key] as JSUint8Array).toDart;

void _handle(JSObject request) {
  final id = _int(request, idField);
  final reply = JSObject()..[idField] = id.toJS;
  final transfer = <JSAny>[];
  JSUint8Array send(Uint8List bytes) {
    final js = bytes.toJS;
    transfer.add(js['buffer']!);
    return js;
  }

  try {
    switch ((request[opField] as JSString).toDart) {
      case opDecodeJ2k:
        final image = decodeJ2k(
          _bytes(request, bytesField),
          reducedResolutionFactor: _int(request, reduceField),
        );
        reply[widthField] = image.width.toJS;
        reply[heightField] = image.height.toJS;
        reply[componentsField] = image.numComponents.toJS;
        reply[pixelsField] = send(image.pixels);
      case opEncodeTiles:
        final encoder = BandTileEncoder((
          jpeg2000: (request[jpeg2000Field] as JSBoolean).toDart,
          quality: _int(request, qualityField),
          jp2kCompressionRatio: (request[ratioField] as JSNumber).toDartDouble,
        ));
        final tiles = encoder.encode(
          RgbaImage(
            _int(request, widthField),
            _int(request, heightField),
            _bytes(request, pixelsField),
          ),
          tileWidth: _int(request, tileWidthField),
          tileLength: _int(request, tileLengthField),
        );
        reply[tilesField] = [for (final tile in tiles) send(tile)].toJS;
      case opEncodeImage:
        final image = RgbaImage(
          _int(request, widthField),
          _int(request, heightField),
          _bytes(request, pixelsField),
        );
        reply[bytesField] = send(
          encodeRgbaImage(
            image,
            _int(request, formatField),
            _int(request, qualityField),
          ),
        );
      default:
        throw StateError('unknown codec worker request');
    }
  } catch (e) {
    reply[errorField] =
        (e is J2kDecodeException
                ? e.message
                : e is J2kEncodeException
                ? e.message
                : '$e')
            .toJS;
    reply[errorKindField] = switch (e) {
      J2kDecodeException() => errorKindJ2kDecode,
      J2kEncodeException() => errorKindJ2kEncode,
      ArgumentError() => errorKindArgument,
      _ => errorKindOther,
    }.toJS;
    transfer.clear();
  }
  _self.postMessage(reply, transfer.toJS);
}
