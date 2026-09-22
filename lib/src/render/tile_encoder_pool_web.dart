import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import '../codec/background_codec_web.dart';
import '../codec/rgba_image.dart';
import '../web/codec_worker_pool.dart';
import '../web/codec_worker_protocol.dart';
import 'band_tile_encoder.dart';

/// Encodes a pyramid export's tiles on the web codec workers: each band's
/// tiles are split between them and encoded in parallel, off the page's
/// main thread. Falls back to encoding on the calling thread where a page
/// can't run workers.
class TileEncoderPool {
  final TileEncoding _encoding;

  /// Created on first use — only when workers aren't available.
  late final _local = BandTileEncoder(_encoding);

  TileEncoderPool._(this._encoding);

  static Future<TileEncoderPool> start(TileEncoding encoding) async =>
      TileEncoderPool._(encoding);

  /// Encodes every tile of a [width]x[height] band of RGBA [pixels], tiled
  /// at [tileWidth]x[tileLength], left to right. The pixels each worker
  /// needs are copied before this returns, so the caller may keep using
  /// [pixels] meanwhile.
  Future<List<Uint8List>> encodeBand(
    Uint8List pixels, {
    required int width,
    required int height,
    required int tileWidth,
    required int tileLength,
  }) async {
    final workers = CodecWorkerPool.instance.size;
    if (workers == 0) {
      return _local.encode(
        RgbaImage(width, height, pixels),
        tileWidth: tileWidth,
        tileLength: tileLength,
      );
    }
    final tileCount = (width + tileWidth - 1) ~/ tileWidth;
    final tilesPerWorker = (tileCount + workers - 1) ~/ workers;
    final chunks = <Future<List<Uint8List>>>[];
    for (var first = 0; first < tileCount; first += tilesPerWorker) {
      final left = first * tileWidth;
      final right = math.min(width, (first + tilesPerWorker) * tileWidth);
      final columns = Uint8List((right - left) * height * 4);
      for (var row = 0; row < height; row++) {
        columns.setRange(
          row * (right - left) * 4,
          (row + 1) * (right - left) * 4,
          pixels,
          (row * width + left) * 4,
        );
      }
      chunks.add(
        _encodeChunk(columns, right - left, height, tileWidth, tileLength),
      );
    }
    final encoded = await Future.wait(chunks);
    return [for (final chunk in encoded) ...chunk];
  }

  Future<List<Uint8List>> _encodeChunk(
    Uint8List columns,
    int width,
    int height,
    int tileWidth,
    int tileLength,
  ) async {
    final js = columns.toJS;
    final request = JSObject()
      ..[pixelsField] = js
      ..[widthField] = width.toJS
      ..[heightField] = height.toJS
      ..[tileWidthField] = tileWidth.toJS
      ..[tileLengthField] = tileLength.toJS
      ..[jpeg2000Field] = _encoding.jpeg2000.toJS
      ..[qualityField] = _encoding.quality.toJS
      ..[ratioField] = _encoding.jp2kCompressionRatio.toJS;
    // [columns] is this chunk's own buffer: hand it over rather than copy.
    final reply = await requestOrNull(opEncodeTiles, request, [js['buffer']!]);
    if (reply == null) {
      return _local.encode(
        RgbaImage(width, height, columns),
        tileWidth: tileWidth,
        tileLength: tileLength,
      );
    }
    return [
      for (final tile in (reply[tilesField] as JSArray<JSUint8Array>).toDart)
        tile.toDart,
    ];
  }

  Future<void> close() async {}
}
