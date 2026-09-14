import 'dart:io';
import 'dart:typed_data';

import '../io/byte_sink.dart';
import '../svs/svs_file.dart';
import 'image_adjustments.dart';
import 'svs_pyramid_export_core.dart';

/// Same as `exportSvsRegionAsSvs`, but streams the encoded file straight to
/// [path] instead of returning it — the memory-bounded way to export a
/// crop that's too large to comfortably hold as a single in-memory
/// [Uint8List].
Future<File> exportSvsRegionAsSvsToFile(
  SvsFile svsFile, {
  required String path,
  required int level,
  required int x,
  required int y,
  required int width,
  required int height,
  int? tileSize,
  int quality = 90,
  SvsExportCompression compression = SvsExportCompression.jpeg,
  double jp2kCompressionRatio = 0,
  bool matchSourceCompression = false,
  int? maxPixels,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
  bool includeLabelAndMacroImages = true,
  bool includeSourceMetadata = true,
  int? levelCount,
  SvsPyramidRebuildEffort effort = SvsPyramidRebuildEffort.balanced,
  void Function(double progress)? onProgress,
}) async {
  final file = File(path);
  final sink = await _openFileSink(file);
  try {
    await streamSvsRegionAsSvs(
      svsFile,
      sink: sink,
      level: level,
      x: x,
      y: y,
      width: width,
      height: height,
      tileSize: tileSize,
      quality: quality,
      compression: compression,
      jp2kCompressionRatio: jp2kCompressionRatio,
      matchSourceCompression: matchSourceCompression,
      maxPixels: maxPixels,
      adjustments: adjustments,
      includeLabelAndMacroImages: includeLabelAndMacroImages,
      includeSourceMetadata: includeSourceMetadata,
      levelCount: levelCount,
      effort: effort,
      onProgress: onProgress,
    );
  } finally {
    // The core only closes the sink once it reaches its own try/finally, so
    // an argument-validation throw before that point would otherwise leak
    // the handle — which on Windows blocks deleting the partial file.
    await sink.close();
  }
  return file;
}

/// Same as `exportSvsRegionAsSvsPreservingLevels`, but streams the encoded
/// file straight to [path] instead of returning it — the memory-bounded way
/// to export a crop that's too large to comfortably hold as a single
/// in-memory [Uint8List].
Future<File> exportSvsRegionAsSvsPreservingLevelsToFile(
  SvsFile svsFile, {
  required String path,
  required int level,
  required int x,
  required int y,
  required int width,
  required int height,
  int? tileSize,
  int quality = 90,
  SvsExportCompression compression = SvsExportCompression.jpeg,
  double jp2kCompressionRatio = 0,
  bool matchSourceCompression = false,
  int? maxPixels,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
  bool includeLabelAndMacroImages = true,
  bool includeSourceMetadata = true,
  SvsPyramidRebuildEffort effort = SvsPyramidRebuildEffort.balanced,
  void Function(double progress)? onProgress,
}) async {
  final file = File(path);
  final sink = await _openFileSink(file);
  try {
    await streamSvsRegionAsSvsPreservingLevels(
      svsFile,
      sink: sink,
      level: level,
      x: x,
      y: y,
      width: width,
      height: height,
      tileSize: tileSize,
      quality: quality,
      compression: compression,
      jp2kCompressionRatio: jp2kCompressionRatio,
      matchSourceCompression: matchSourceCompression,
      maxPixels: maxPixels,
      adjustments: adjustments,
      includeLabelAndMacroImages: includeLabelAndMacroImages,
      includeSourceMetadata: includeSourceMetadata,
      effort: effort,
      onProgress: onProgress,
    );
  } finally {
    // See the matching comment in exportSvsRegionAsSvsToFile.
    await sink.close();
  }
  return file;
}

Future<RandomAccessByteSink> _openFileSink(File file) async {
  if (await file.exists()) await file.delete();
  final raf = await file.open(mode: FileMode.write);
  return _FileByteSink(raf);
}

class _FileByteSink implements RandomAccessByteSink {
  final RandomAccessFile _raf;
  bool _closed = false;
  _FileByteSink(this._raf);

  @override
  Future<void> writeFrom(List<int> bytes) => _raf.writeFrom(bytes);

  @override
  Future<void> setPosition(int position) => _raf.setPosition(position);

  @override
  Future<int> position() => _raf.position();

  /// Idempotent: the streaming core closes the sink itself on its normal
  /// path, and the `*ToFile` wrappers close it again to cover early throws —
  /// a second `RandomAccessFile.close` would fail with "File closed".
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  }
}
