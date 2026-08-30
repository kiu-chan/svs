import 'dart:io';

import '../svs/svs_file.dart';
import 'image_adjustments.dart';
import 'image_export.dart';

/// Same as [exportSvsRegion], but writes the encoded bytes straight to
/// [path] instead of returning them.
Future<File> exportSvsRegionToFile(
  SvsFile svsFile, {
  required String path,
  required int level,
  required int x,
  required int y,
  required int width,
  required int height,
  required SvsImageFormat format,
  int quality = 92,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
  void Function(double progress)? onProgress,
}) async {
  final bytes = await exportSvsRegion(
    svsFile,
    level: level,
    x: x,
    y: y,
    width: width,
    height: height,
    format: format,
    quality: quality,
    adjustments: adjustments,
    onProgress: onProgress,
  );
  return File(path).writeAsBytes(bytes);
}

/// Same as [exportAssociatedImage], but writes the encoded bytes straight to
/// [path] instead of returning them.
Future<File> exportAssociatedImageToFile(
  SvsAssociatedImage image, {
  required String path,
  required SvsImageFormat format,
  int quality = 92,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
}) async {
  final bytes = await exportAssociatedImage(
    image,
    format: format,
    quality: quality,
    adjustments: adjustments,
  );
  return File(path).writeAsBytes(bytes);
}

/// Same as [exportSvsLevel], but writes the encoded bytes straight to [path]
/// instead of returning them.
Future<File> exportSvsLevelToFile(
  SvsFile svsFile, {
  required String path,
  required int level,
  required SvsImageFormat format,
  int quality = 92,
  int? maxPixels,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
  void Function(double progress)? onProgress,
}) async {
  final bytes = await exportSvsLevel(
    svsFile,
    level: level,
    format: format,
    quality: quality,
    maxPixels: maxPixels,
    adjustments: adjustments,
    onProgress: onProgress,
  );
  return File(path).writeAsBytes(bytes);
}
