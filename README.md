# svs

A Flutter library for displaying Aperio SVS (whole-slide image) files.

SVS is a pyramidal, tiled TIFF-based format used to store gigapixel
whole-slide microscopy/pathology images. `svs` reads the pyramid directly
and streams only the tiles the current viewport needs — the full image is
never loaded into memory, however large the slide.

## Features

* **Pan & zoom viewer** (`SvsImageView`) with a minimap, zoom percentage,
  and a physical scale bar (µm/mm, derived from the slide's own
  microns-per-pixel metadata) — each independently toggleable
  (`showMinimap`/`showZoomLevel`/`showScaleBar`).
* **Level-of-detail tile streaming**: only the visible region's tiles are
  fetched and decoded, at the resolution level that matches the current
  zoom — panning and zooming a multi-gigapixel slide stays smooth.
* **Background isolate decoding**: tile I/O and JPEG2000 decode run off the
  main isolate, so the UI thread stays responsive.
* **JPEG and JPEG2000 tiles**, the two compressions Aperio actually ships
  (`Compression` 7 and 33005) — JPEG2000 via
  [`openjpeg_ffi`](https://pub.dev/packages/openjpeg_ffi).
* **Associated images and metadata**: thumbnail/label/macro images, and
  parsed Aperio metadata (magnification, microns-per-pixel, and the rest of
  the pipe-delimited `ImageDescription` block).
* **Full metadata dump** (`SvsFile.readInfo`): every TIFF tag on every
  pyramid level and associated image, decoded — not just the fields this
  package parses directly — for callers that want the whole file's own
  metadata, or a specific tag this package doesn't otherwise surface.
* **Region cropping** (`readSvsRegion`): decode an arbitrary rectangle of any
  pyramid level to a single composited image, without loading the whole
  level.
* **Crop to a new pyramidal `.svs`** (`exportSvsRegionAsSvs`): re-encode a
  cropped region as a brand new, valid multi-level pyramidal `.svs` file —
  not a flat raster image — openable by this package (or any other
  tiled-TIFF/OpenSlide-aware tool) and pannable/zoomable like any other
  slide.
* **Brightness/contrast/shadow/highlight adjustment**
  (`SvsImageAdjustments`): applied identically live (cheap to change every
  frame — a GPU color filter) and on export, so preview and output always
  match.
* **Annotations** (`SvsAnnotationController`): draw points, rectangles,
  polylines, and polygons over the slide — anchored in level-0 pixel space,
  so they stay put across pan/zoom — with tap-to-select, hit-testing, and
  JSON persistence.
* **Measurement** (`measureAnnotation`): live physical length/area labels on
  line, rectangle, and polygon annotations (including while drawing),
  computed from the slide's own microns-per-pixel metadata.
* **Export to common image formats** (`exportSvsRegion`, `exportAssociatedImage`,
  `exportSvsLevel`): encode a crop, an associated image, or a whole pyramid
  level to PNG, JPEG, BMP, TIFF, or WebP bytes.
* Memory-pressure aware tile cache, and active cancellation of in-flight
  tile requests once they scroll out of view.
* **Persistent disk tile cache** (`DiskTileCache`, opt-in): decoded tiles
  survive across app restarts, so re-viewing the same region of a slide
  skips both the tile fetch and — for JPEG2000 slides — the wavelet decode.

## Getting started

```yaml
dependencies:
  svs: ^1.0.0
```

## Usage

```dart
import 'package:svs/svs.dart';
import 'package:flutter/widgets.dart';

final svsFile = await SvsFile.open('/path/to/slide.svs');

// Anywhere in a widget tree:
SvsImageView(svsFile: svsFile);

// When done:
await svsFile.close();
```

`SvsImageView` handles pan/zoom gestures, tile streaming, and the minimap/
HUD on its own — no further wiring needed. Each overlay can be turned off
independently:

```dart
SvsImageView(
  svsFile: svsFile,
  showMinimap: false, // skips decoding the thumbnail entirely, not just hiding it
  showZoomLevel: false,
  showScaleBar: false,
);
```

### Persistent tile cache

By default, decoded tiles are cached in memory only — closing and
re-opening the same slide decodes everything again from scratch. Pass a
`DiskTileCache` to keep decoded tiles on disk between sessions, scoped to a
directory unique to that slide (mixing tiles from different slides in one
directory isn't supported — their level/tile-x/tile-y keys can collide).
`svs` itself has no opinion on *where* that directory lives — pick one with
your own app's `path_provider` dependency (or any other means of locating a
writable directory):

```dart
import 'package:path_provider/path_provider.dart';

final cacheDir = Directory(
  '${(await getApplicationCacheDirectory()).path}/svs_tiles/${svsFile.path.hashCode}',
);
final diskCache = await DiskTileCache.open(cacheDir); // 500 MB budget by default

SvsImageView(svsFile: svsFile, diskCache: diskCache);
```

Bounded by decoded-pixel byte budget and evicted LRU, same policy as the
in-memory cache — pass `maxBytes` to `DiskTileCache.open` to change it.
Most valuable for JPEG2000 slides, whose wavelet decode is comparatively
expensive to redo; for JPEG slides the win is mainly skipping repeated file
I/O.

### Cropping a region

To pull out an arbitrary rectangle — e.g. exporting a region of interest, or
generating a fixed-size tile at a chosen resolution — use `readSvsRegion`.
Coordinates are in the given pyramid level's own pixel space (level 0 is
full resolution), and the rectangle may hang off the level's edges; the
out-of-bounds part comes back transparent:

```dart
final region = await readSvsRegion(
  svsFile,
  level: 0,
  x: 1000,
  y: 2000,
  width: 512,
  height: 512,
);
// region is a dart:ui Image — draw it, or convert to bytes:
final bytes = await region.toByteData(format: ui.ImageByteFormat.png);
region.dispose();
```

`readSvsRegion` must be called on the main isolate (like any other
`dart:ui` decode) and stitches together only the tiles the rectangle
actually overlaps.

### Reading a file's full metadata

`SvsFile.readInfo` dumps every TIFF tag of every pyramid level and
associated image, decoded regardless of type — beyond the Aperio fields
`SvsFile.metadata` already parses directly:

```dart
final info = await svsFile.readInfo();
print(info.isBigTiff); // true/false
print(info.levels[0].tags[256]); // ImageWidth, raw tag ID
print(info.levels[0].namedTags['ImageWidth']); // same, by name
```

For just a few specific tags instead of everything, use `readTags` on a
level or associated image directly:

```dart
final tags = await svsFile.levels[0].readTags([256, 257]); // ImageWidth, ImageLength
```

### Converting to other image formats

`encodeSvsImage` turns any decoded image (from `readSvsRegion` or
`decodeAssociatedImage`) into PNG, JPEG, BMP, TIFF, or WebP bytes. The
`exportSvs*` wrappers combine decoding and encoding into one call and
dispose the intermediate image for you:

```dart
// A cropped region, as JPEG:
final jpegBytes = await exportSvsRegion(
  svsFile,
  level: 0,
  x: 1000, y: 2000, width: 512, height: 512,
  format: SvsImageFormat.jpeg,
  quality: 90, // 1-100, JPEG only — every other format is lossless
);
await File('region.jpg').writeAsBytes(jpegBytes);

// The slide's label image, as PNG:
final label = svsFile.associatedImages
    .firstWhere((a) => a.kind == AssociatedImageKind.label);
final pngBytes = await exportAssociatedImage(label, format: SvsImageFormat.png);

// An entire (coarse) pyramid level, as TIFF:
final levelBytes = await exportSvsLevel(
  svsFile,
  level: svsFile.levels.length - 1, // the smallest/coarsest level
  format: SvsImageFormat.tiff,
);
```

Each of those has a `...ToFile` counterpart (`exportSvsRegionToFile`,
`exportAssociatedImageToFile`, `exportSvsLevelToFile`) that writes straight
to a `path` and skips the manual `writeAsBytes` step:

```dart
await exportSvsRegionToFile(
  svsFile,
  path: 'region.jpg',
  level: 0,
  x: 1000, y: 2000, width: 512, height: 512,
  format: SvsImageFormat.jpeg,
);
```

`exportSvsLevel` refuses (throws `ArgumentError`) to export a level over
`maxPixels` (64,000,000 px by default, roughly an 8000x8000 image) without
an explicit opt-in — level 0 of a real slide can be 100,000+ px per side,
and compositing/re-encoding one whole-hog can mean gigabytes of RAM and a
multi-minute encode. Crop with `exportSvsRegion` or target a coarser level
instead unless you really need the full-resolution export.

### Brightness/contrast/shadow/highlight adjustment

`SvsImageAdjustments` applies identically to a live `SvsImageView` and to
every export function — the same values always produce the same result in
both places:

```dart
const adjustments = SvsImageAdjustments(
  brightness: 0.1,
  contrast: 0.2,
  shadows: 0.3, // lifts dark regions
  highlights: -0.2, // brightens light regions further (protects less)
);

SvsImageView(svsFile: svsFile, adjustments: adjustments); // live preview

final bytes = await exportSvsRegion(
  svsFile,
  level: 0, x: 1000, y: 2000, width: 512, height: 512,
  format: SvsImageFormat.png,
  adjustments: adjustments, // same look in the exported file
);
```

Every parameter is nominally `-1..1`, with `0` meaning no change
(`SvsImageAdjustments.none`, the default everywhere).

### Cropping to a new pyramidal `.svs` file

`exportSvsRegionAsSvs` crops a region like `exportSvsRegion`, but re-encodes
it as a brand new, valid multi-level pyramidal `.svs` file instead of a flat
raster image — reopenable with `SvsFile.open` and pannable/zoomable like any
other slide:

```dart
final croppedSvsBytes = await exportSvsRegionAsSvs(
  svsFile,
  level: 0,
  x: 1000, y: 2000, width: 4096, height: 4096,
  tileSize: 256, // matches real Aperio files
  quality: 90,
);
await File('cropped_region.svs').writeAsBytes(croppedSvsBytes);

// Or straight to a file:
await exportSvsRegionAsSvsToFile(
  svsFile,
  path: 'cropped_region.svs',
  level: 0,
  x: 1000, y: 2000, width: 4096, height: 4096,
);
```

Levels are generated by halving the previous level's dimensions
(box-filter downsampled) until one fits in a single tile — the same shape a
real Aperio pyramid takes.

`compression` picks the pyramid's tile encoding — `SvsExportCompression.jpeg`
(the default; `quality` applies) or `.jpeg2000` (mathematically lossless by
default, or lossy at a chosen `jp2kCompressionRatio`; typically a smaller
file than JPEG at comparable visual quality, at the cost of slower
encoding):

```dart
await exportSvsRegionAsSvsToFile(
  svsFile,
  path: 'cropped_region.svs',
  level: 0,
  x: 1000, y: 2000, width: 4096, height: 4096,
  compression: SvsExportCompression.jpeg2000,
  jp2kCompressionRatio: 0, // 0 = lossless (default); e.g. 20 = ~20:1 smaller
);
```

The source file's own label/macro images and other `ImageDescription`
metadata (Filename, Date, ScanScope ID, etc.) are carried into the exported
file by default — `includeLabelAndMacroImages`/`includeSourceMetadata`
(both default `true`) opt either out, e.g. before sharing a crop outside the
context that made the original slide's label or scanner details meaningful.

### Annotations

`SvsAnnotationController` owns the annotations drawn over an `SvsImageView`
and the interactive state of drawing a new one. Pass the same controller to
the view; it renders the annotations and routes pointer gestures to build
new shapes while `drawMode` isn't `SvsAnnotationDrawMode.none`:

```dart
final annotations = SvsAnnotationController(drawColor: Colors.red);

SvsImageView(
  svsFile: svsFile,
  annotationController: annotations,
  onAnnotationTap: (a) => print('tapped ${a?.id}'),
);

// Start drawing a rectangle — a press-drag-release on the view now draws
// one instead of panning. Switch back to `.none` to resume pan/zoom.
annotations.drawMode = SvsAnnotationDrawMode.rectangle;

// Point mode: each tap commits a point immediately.
annotations.drawMode = SvsAnnotationDrawMode.point;

// Polygon/polyline mode: each tap adds a vertex; call finishPath() (e.g.
// from a "Done" button) once there are enough.
annotations.drawMode = SvsAnnotationDrawMode.polygon;
// ...taps happen via the view...
annotations.finishPath();
```

`SvsAnnotationController.annotations` is a live `List<SvsAnnotation>`;
`add`, `remove`, `update`, and `clear` all notify listeners (including the
view). Tapping the view while `drawMode` is `none` hit-tests existing
annotations, auto-selects the one hit (or clears selection on a miss), and
calls `onAnnotationTap`.

Every `SvsAnnotation`'s `points` are in level-0 pixel coordinates, so they
stay valid across pan and zoom. Persist a set with `toJsonList()` /
`loadFromJsonList()` (JSON-safe maps — round-trip through `jsonEncode`/
`jsonDecode` yourself):

```dart
final jsonString = jsonEncode(annotations.toJsonList());
// ...later...
annotations.loadFromJsonList(jsonDecode(jsonString) as List);
```

### Measurement

Whenever the slide has microns-per-pixel metadata (`SvsFile.metadata.mppX`/
`mppY`), `SvsImageView` shows a live length/area label on every polyline,
rectangle, and polygon annotation — including the one currently being
drawn, so dragging out a rectangle or placing polygon vertices doubles as a
ruler. Set `showMeasurements: false` to turn the labels off.

The same computation is available directly via `measureAnnotation`, for
measuring annotations outside the view (e.g. in a report):

```dart
final m = measureAnnotation(
  annotation,
  mppX: svsFile.metadata.mppX,
  mppY: svsFile.metadata.mppY,
);
print(m.lengthMicrons); // null if unmeasurable (e.g. a point, or no mpp)
print(m.areaMicronsSquared); // null for point/polyline shapes
```

See [`example/`](example/) for a minimal runnable app, or
[`svs_example`](https://github.com/kiu-chan/svs_example) for a
full-featured demo (file picker, associated-image previews, metadata
inspector) built on top of this package.

## Additional information

File issues or feature requests at the
[issue tracker](https://github.com/kiu-chan/svs/issues). Contributions are
welcome via pull request.

If this package saves you time, consider supporting its development:

[![Support me on Ko-fi](https://storage.ko-fi.com/cdn/kofi5.png?v=3)](https://ko-fi.com/monlycute)

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
