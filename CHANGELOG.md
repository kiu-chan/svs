## 1.0.0

* `SvsFile.readInfo`, `SvsLevel.readAllTags`/`readTags`,
  `SvsAssociatedImage.readAllTags`/`readTags`: read every TIFF tag on any
  level/associated-image IFD (or just a chosen subset), decoded regardless of
  type (ints, ASCII, RATIONAL/SRATIONAL, FLOAT/DOUBLE, raw bytes) — a full
  structured dump of the file's own metadata, alongside the existing
  narrower accessors (`metadata.raw`, level/associated-image geometry) for
  callers that only need specific fields. `SvsFileInfo`/`SvsIfdInfo` carry
  the result, with a `namedTags` getter (via the new `tiffTagName`) for
  presenting tag IDs as human-readable names.
* `SvsImageAdjustments`: brightness/contrast/shadow/highlight adjustment,
  applied identically live (`SvsImageView.adjustments`, GPU-accelerated —
  cheap to change every frame) and on export (every `exportSvs*`/
  `encodeSvsImage` function's new `adjustments` parameter) — both derive
  from the same affine transform, so the two are always in sync.
* `exportSvsRegionAsSvs`/`exportSvsRegionAsSvsToFile`: crop a region and
  re-encode it as a brand new, valid multi-level pyramidal `.svs` file (a
  tiled BigTIFF with JPEG-compressed tiles and an Aperio-style
  `ImageDescription`) instead of a single flat raster image — the result can
  be reopened with `SvsFile.open`, by this package or any other tiled-TIFF/
  OpenSlide-aware tool, and panned/zoomed like any other slide.

## 0.3.0

* `SvsAnnotationController`, `SvsAnnotation`: draw and manage point,
  rectangle, polyline, and polygon annotations over an `SvsImageView`,
  anchored in level-0 pixel space so they stay put across pan/zoom. Pass a
  controller to `SvsImageView.annotationController` to render its
  annotations and route pointer gestures to it while `drawMode` isn't
  `SvsAnnotationDrawMode.none` — point mode commits on tap, rectangle mode
  draws on drag, polyline/polygon mode adds a vertex per tap (call
  `finishPath()` to commit). Tapping in view mode (`drawMode.none`)
  hit-tests and auto-selects an existing annotation, and fires the new
  `SvsImageView.onAnnotationTap` callback. Annotations round-trip to JSON
  via `SvsAnnotationController.toJsonList`/`loadFromJsonList`.
* `measureAnnotation`: physical length (and, for rectangles/polygons, area)
  of an `SvsAnnotation`, computed from the slide's microns-per-pixel.
  `SvsImageView` shows this as a live label on line/rectangle/polygon
  annotations — including the one being drawn, so drawing doubles as a
  ruler — toggle with the new `SvsImageView.showMeasurements`.
* `DiskTileCache`: an opt-in persistent tile cache. Pass one to the new
  `SvsImageView.diskCache` and decoded tiles are read from disk first (and
  written back after a fresh decode), so re-viewing the same region of a
  slide — even across app restarts — skips the tile fetch and, for JPEG2000
  slides, the wavelet decode. Byte-budgeted and LRU-evicted like the
  existing in-memory `TileCache`.

## 0.2.0

* `readSvsRegion`: crops an arbitrary rectangle of any pyramid level to a
  single composited image, stitching together only the tiles it overlaps.
  The rectangle may hang off the level's edges; the out-of-bounds part
  decodes transparent.
* `encodeSvsImage`, `exportSvsRegion`, `exportAssociatedImage`,
  `exportSvsLevel`: encode a decoded image (a crop, an associated image, or
  a whole pyramid level) to PNG, JPEG, BMP, TIFF, or WebP bytes, via the new
  `image` dependency. `exportSvsLevel` guards against accidentally
  compositing/encoding a gigapixel level whole. Each has a `...ToFile`
  counterpart (`exportSvsRegionToFile`, `exportAssociatedImageToFile`,
  `exportSvsLevelToFile`) that writes straight to a path instead of
  returning bytes.

## 0.1.0

* Initial release.
* `SvsFile`: opens Aperio SVS (and generic tiled TIFF) files — resolution
  pyramid levels, associated images (thumbnail/label/macro), and parsed
  Aperio metadata (magnification, microns-per-pixel).
* `SvsImageView`: a pan/zoom widget streaming only the tiles the current
  viewport needs, at the resolution level matching the current zoom.
  Includes a minimap, zoom percentage, and a physical (µm/mm) scale bar.
* JPEG (`Compression=7`) and JPEG2000 (`Compression=33005`) tile decoding —
  JPEG2000 via the `openjpeg_ffi` package.
* Tile fetch and JPEG2000 decode run on background isolates; a
  memory-budgeted LRU tile cache responds to OS memory-pressure signals and
  actively cancels in-flight requests for tiles scrolled out of view.
