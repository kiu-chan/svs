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
  void Function(double progress)? onProgress,
}) async {
  final file = File(path);
  await streamSvsRegionAsSvs(
    svsFile,
    sink: await _openFileSink(file),
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
    onProgress: onProgress,
  );
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
  void Function(double progress)? onProgress,
}) async {
  final file = File(path);
  await streamSvsRegionAsSvsPreservingLevels(
    svsFile,
    sink: await _openFileSink(file),
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
    onProgress: onProgress,
  );
  return file;
}

Future<RandomAccessByteSink> _openFileSink(File file) async {
  if (await file.exists()) await file.delete();
  final raf = await file.open(mode: FileMode.write);
  return _FileByteSink(raf);
}

class _FileByteSink implements RandomAccessByteSink {
  final RandomAccessFile _raf;
  _FileByteSink(this._raf);

  @override
  Future<void> writeFrom(List<int> bytes) => _raf.writeFrom(bytes);

  @override
  Future<void> setPosition(int position) => _raf.setPosition(position);

  @override
  Future<int> position() => _raf.position();

  @override
  Future<void> close() => _raf.close();
}
