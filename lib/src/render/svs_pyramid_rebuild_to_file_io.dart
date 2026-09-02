import 'dart:io';

import '../svs/svs_file.dart';
import 'image_adjustments.dart';
import 'svs_pyramid_export.dart';
import 'svs_pyramid_export_to_file_io.dart';

/// Same as `rebuildSvsPyramid`, but streams the encoded file straight to
/// [path] instead of returning it — the memory-bounded way to rebuild a
/// slide too large to comfortably hold as a single in-memory `Uint8List`.
///
/// Writes a brand new file at [path]; [svsFile] and its own underlying
/// source file (if any) are left open and untouched — this is the "create a
/// new file next to the original" option (just pass a path next to
/// [svsFile.path]). Use [rebuildSvsPyramidInPlace] instead to overwrite the
/// source file itself.
Future<File> rebuildSvsPyramidToFile(
  SvsFile svsFile, {
  required String path,
  int? levelCount,
  int? tileSize,
  int quality = 90,
  SvsExportCompression compression = SvsExportCompression.jpeg,
  double jp2kCompressionRatio = 0,
  bool matchSourceCompression = true,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
  bool includeLabelAndMacroImages = true,
  bool includeSourceMetadata = true,
  SvsPyramidRebuildEffort effort = SvsPyramidRebuildEffort.balanced,
  void Function(double progress)? onProgress,
}) {
  final level0 = svsFile.levels[0];
  return exportSvsRegionAsSvsToFile(
    svsFile,
    path: path,
    level: 0,
    x: 0,
    y: 0,
    width: level0.width,
    height: level0.height,
    tileSize: tileSize,
    quality: quality,
    compression: compression,
    jp2kCompressionRatio: jp2kCompressionRatio,
    matchSourceCompression: matchSourceCompression,
    adjustments: adjustments,
    includeLabelAndMacroImages: includeLabelAndMacroImages,
    includeSourceMetadata: includeSourceMetadata,
    levelCount: levelCount,
    effort: effort,
    onProgress: onProgress,
  );
}

/// Same as [rebuildSvsPyramidToFile], but overwrites [svsFile]'s own source
/// file instead of writing to a separate path — the "modify the original
/// file" option ([rebuildSvsPyramidToFile] is the "new file next to it" one).
///
/// Requires [svsFile] to have been opened with [SvsFile.open] (a real
/// filesystem path) rather than [SvsFile.openBytes] — throws [ArgumentError]
/// otherwise, since there's then no source file to overwrite.
///
/// The rebuilt pyramid is first streamed in full to a temporary file next to
/// the original (`<path>.rebuild.tmp`, same directory, so the final swap
/// below is a same-filesystem rename rather than a copy) while [svsFile]
/// stays open and readable throughout — so a failure partway through the
/// rebuild itself (a decode error, a thrown [ArgumentError], the app being
/// killed) leaves the original completely untouched, just an orphaned temp
/// file cleaned up here on the next successful call (or safe to delete by
/// hand).
///
/// Only once the rebuild fully succeeds does this: close [svsFile] (a real
/// file handle can't be replaced out from under itself on every platform),
/// then rename the temp file over [path] — `dart:io`'s [File.rename]
/// already replaces an existing destination file for us, so this is a
/// single atomic-per-platform swap, not a separate delete-then-rename with
/// its own failure window. **Note:** [svsFile] is closed as part of this
/// step regardless of whether the rename that follows succeeds — don't use
/// it afterwards either way; on success, use the [SvsFile] this function
/// returns instead, and on failure, reopen [path] yourself if you need a
/// handle on it again (the original file's contents are unaffected by a
/// failed rename).
///
/// Returns a freshly-[SvsFile.open]ed handle on the rebuilt file at [path].
Future<SvsFile> rebuildSvsPyramidInPlace(
  SvsFile svsFile, {
  int? levelCount,
  int? tileSize,
  int quality = 90,
  SvsExportCompression compression = SvsExportCompression.jpeg,
  double jp2kCompressionRatio = 0,
  bool matchSourceCompression = true,
  SvsImageAdjustments adjustments = SvsImageAdjustments.none,
  bool includeLabelAndMacroImages = true,
  bool includeSourceMetadata = true,
  SvsPyramidRebuildEffort effort = SvsPyramidRebuildEffort.balanced,
  void Function(double progress)? onProgress,
}) async {
  final path = svsFile.path;
  if (path == null) {
    throw ArgumentError(
      'rebuildSvsPyramidInPlace requires svsFile.path (i.e. svsFile must '
      'have been opened via SvsFile.open, not SvsFile.openBytes) — there is '
      'no source file to overwrite otherwise. Use rebuildSvsPyramid or '
      'rebuildSvsPyramidToFile instead.',
    );
  }

  final tempFile = File('$path.rebuild.tmp');
  try {
    await rebuildSvsPyramidToFile(
      svsFile,
      path: tempFile.path,
      levelCount: levelCount,
      tileSize: tileSize,
      quality: quality,
      compression: compression,
      jp2kCompressionRatio: jp2kCompressionRatio,
      matchSourceCompression: matchSourceCompression,
      adjustments: adjustments,
      includeLabelAndMacroImages: includeLabelAndMacroImages,
      includeSourceMetadata: includeSourceMetadata,
      effort: effort,
      onProgress: onProgress,
    );
  } catch (_) {
    if (await tempFile.exists()) await tempFile.delete();
    rethrow;
  }

  await svsFile.close();
  try {
    await tempFile.rename(path);
  } catch (_) {
    if (await tempFile.exists()) await tempFile.delete();
    rethrow;
  }
  return SvsFile.open(path);
}
