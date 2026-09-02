import 'dart:typed_data';

import '../svs/svs_file.dart';
import 'image_adjustments.dart';
import 'region_decoder.dart';
import 'svs_pyramid_export.dart';

export 'svs_pyramid_export_core.dart' show SvsPyramidRebuildEffort;

/// Re-encodes [svsFile]'s entire level-0 extent as a brand new pyramidal
/// `.svs` file — the same underlying machinery as [exportSvsRegionAsSvs]
/// (crop = the whole slide), but exposed as a first-class "change this
/// slide's own pyramid level count" operation rather than a crop.
/// Reopenable with [SvsFile.open] and pannable/zoomable like any other
/// slide, same as any export in this package.
///
/// [levelCount] controls the output's number of pyramid levels:
/// * `null` (default) regenerates the maximal, smoothest 2x-halved cascade
///   down to one tile. For a source whose own pyramid has few or unevenly-
///   spaced levels (real Aperio slides often aren't 2x-stepped — e.g.
///   downsample 1x, 4x, 16x), this *increases* the level count and evens
///   out the downsample steps between what's actually generated, which is
///   what makes zooming through the result feel smooth (no visible "pop"
///   from a big jump between levels). This is always the maximum useful
///   level count — nothing finer exists to generate beyond it.
/// * An explicit, smaller value truncates that cascade early — *decreasing*
///   the level count relative to the natural (or source) pyramid. The
///   coarsest generated level then isn't guaranteed to fit in one tile, but
///   the file is correspondingly smaller and faster to build.
/// * A value `>=` the natural count is a no-op, clamped down to it.
///
/// [matchSourceCompression] defaults to `true` here — unlike
/// [exportSvsRegionAsSvs]'s crop-oriented `false` default — since rebuilding
/// a *whole* slide's pyramid should stay visually/size-equivalent to the
/// source unless told otherwise. Pass `false` (with your own `compression`/
/// `quality`/`jp2kCompressionRatio`) to pick the encoding yourself instead.
///
/// Every other parameter ([tileSize], [quality], [compression],
/// [jp2kCompressionRatio], [adjustments], [includeLabelAndMacroImages],
/// [includeSourceMetadata], [effort], [onProgress]) means the same thing as
/// on [exportSvsRegionAsSvs].
///
/// Built by streaming the source band-by-band and buffering the output
/// pyramid in memory as it's built, so it needs as many bytes of RAM as the
/// output ends up being. For a slide large enough that this is a concern,
/// prefer `rebuildSvsPyramidToFile` (writes a new file) or
/// `rebuildSvsPyramidInPlace` (overwrites the source file itself) instead —
/// both native platforms only, where a real filesystem exists — which
/// stream straight to disk.
///
/// Must run on the main isolate, like [readSvsRegion].
Future<Uint8List> rebuildSvsPyramid(
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
}) {
  final level0 = svsFile.levels[0];
  return exportSvsRegionAsSvs(
    svsFile,
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
