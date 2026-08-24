## 1.0.3

* Fixed: a right/bottom-edge tile whose JPEG decode legally comes back
  *smaller* than its pyramid level's nominal tile size (unpadded — some
  encoders don't pad boundary tiles up to a full block) used to get stretched
  to fill the full nominal-size destination rect anyway, distorting slide
  content near the level's true edge; since each level's width/height leaves
  a different remainder past its last full tile, the stretch factor — and so
  the visible distortion — differed level to level. `SvsImageView` now sizes
  each tile's destination rect from that tile's own decoded dimensions
  instead of assuming every tile is nominal-sized.
* Fixed: `exportSvsRegionAsSvs`/`exportSvsRegionAsSvsToFile` never wrote a
  thumbnail into the cropped `.svs` file they produced, so reopening one with
  `SvsImageView` never showed a minimap (no associated image of
  `AssociatedImageKind.thumbnail` for it to find). The exported file now
  carries a thumbnail — the coarsest generated pyramid level's own image,
  reused rather than re-decoded — same as a real Aperio file's own thumbnail.
  The same export also now carries over the source file's label/macro
  associated images (copied byte-for-byte, no decode/re-encode needed — they
  describe the whole physical slide, unaffected by the crop) and every other
  `ImageDescription` field the source carried (Filename, Date, Time, User,
  ScanScope ID, etc. — previously only `AppMag`/`MPP` survived), excluding
  the handful of fields (`Left`/`Top`/`OriginalWidth`/`OriginalHeight`) that
  describe the source image's position within the *original* slide and would
  be wrong once carried into a crop. Both are on by default but optional —
  new `includeLabelAndMacroImages`/`includeSourceMetadata` parameters on
  `exportSvsRegionAsSvs`/`exportSvsRegionAsSvsToFile` (default `true` for
  both) let a caller opt out of either, e.g. before sharing a crop outside
  the context that made the original slide's label or scanner details
  meaningful.
* The zoom-percentage HUD chip's tap-to-explain dialog (added in 1.0.2) is
  removed — it added interaction surface for a detail most integrators don't
  need explained in-app. In its place, a new chip shows how much of the
  whole slide the viewport currently covers (100% at the initial/minimum
  zoom, shrinking as the view zooms in) — a more broadly useful piece of
  context than the removed dialog. The magnification chip (when the slide's
  `AppMag` is known) is unchanged aside from also losing its tap dialog.

## 1.0.2

* Fixed: a JPEG-compressed slide tile/associated image whose TIFF
  `PhotometricInterpretation` says `RGB` (literal RGB samples, not
  YCbCr-encoded — some Aperio files) used to come back with a visible color
  cast, most noticeable as a gray/lavender tint across the slide's
  background — `dart:ui`'s JPEG codec has no visibility into that TIFF-level
  tag, so it always applied a YCbCr->RGB transform the samples never needed,
  and the previous fix (inverting that transform on the *decoded* pixels)
  couldn't recover channels the wrong transform had already clipped at 0 or
  255, which near-white background pixels routinely are. Now fixed at the
  source: an Adobe `transform=0` marker is inserted into the JPEG bytes
  before decode, so the codec skips the color transform entirely and decodes
  the true samples losslessly.
* Fixed: a JPEG tile at a pyramid level's right or bottom edge is padded up
  to the full nominal tile size by the encoder (JPEG requires whole-block
  data); that padding was being drawn at full size along with the rest of
  the tile, bleeding a strip of stretched/duplicate-looking content past the
  level's true edge into what should be empty space beyond the slide.
  `SvsImageView` now clips each level's tiles to that level's real extent.
* `SvsImageView.fit` (`SvsImageFit.contain`/`cover`) and `backgroundColor`:
  control how the initial view fits a slide whose aspect ratio doesn't match
  the viewport's — `contain` (the default, previous/only behavior) letterboxes;
  `cover` fills the viewport completely, cropping the slide's edges instead.
  `backgroundColor` (default unchanged) sets the fill for any letterboxed or
  not-yet-decoded area, so it can be made to match the surrounding UI. Also
  now documented on the class itself as expected behavior, not a rendering
  bug.
* The zoom-percentage HUD chip is now tappable, showing a short explanation
  of what the percentage means; when the slide's scan magnification
  (`AppMag`) is known, a second, also-tappable magnification chip (e.g.
  "20x") sits next to it.

## 1.0.1

* `exportSvsRegionAsSvs`/`exportSvsRegionAsSvsToFile`: no pixel-count limit by
  default anymore — crop any size region, including a whole slide's full
  extent. The old `maxPixels` safety cap existed because the previous
  implementation decoded the entire requested region into one full-resolution
  in-memory buffer before doing anything else; the export is now built by
  streaming the source band-by-band straight to the output file, so memory
  use stays bounded by `tileSize * width` rather than the full crop area.
  `maxPixels` is still accepted (now optional, default `null`) for a caller
  that wants to opt back into a fail-fast size budget. `exportSvsLevel`'s
  `maxPixels` default changes the same way, for consistency, though its
  underlying flat-raster output still needs the whole level in memory
  regardless — prefer `exportSvsRegionAsSvsToFile` for a very large export.
* `exportSvsRegionAsSvs`/`exportSvsRegionAsSvsToFile`/`exportSvsRegion`/
  `exportSvsRegionToFile`/`exportSvsLevel`/`exportSvsLevelToFile`/
  `readSvsRegion`: new `onProgress` parameter (0.0-1.0), invoked as the
  export/decode progresses.

## 1.0.0

* Fixed: with an `annotationController` attached, a two-finger pinch could
  occasionally fail to zoom at all (`ScaleGestureRecognizer` computing
  `scale == 1.0` despite a finger clearly moving), even in `drawMode.none`
  where pan/zoom is supposed to work normally. `GestureDetector`'s own
  `onTapUp` (a `TapGestureRecognizer`) and the pan/zoom `onScaleStart`/
  `Update`/`End` (a `ScaleGestureRecognizer`) were both live for the same
  pointer, and having the two recognizers compete in the same gesture arena
  made the scale recognizer's own math unreliable. Tap detection no longer
  goes through a separate `TapGestureRecognizer` at all — it's synthesized
  from raw `Listener` pointer events instead (which don't participate in the
  gesture arena), so there's nothing left for `ScaleGestureRecognizer` to
  compete with.
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
* `SvsImageView.showMinimap`/`showZoomLevel`/`showScaleBar`: independently
  toggle the minimap, the zoom-percentage HUD text, and the physical scale
  bar — all default to `true` (unchanged behavior). `showMinimap: false`
  skips decoding the slide's thumbnail entirely, not just hiding it.
* Fixed: `SvsImageView`'s zoom-percent HUD could jump to a garbage value
  while drawing a point/polyline/polygon annotation. Only rectangle mode
  used to suppress pan/zoom while drawing; point/polyline/polygon mode
  placed vertices via tap but left the underlying pan/zoom gesture live
  underneath, so a quick run of taps could occasionally be misread as a
  pinch. Pan/zoom is now fully suppressed (`GestureDetector`'s scale
  callbacks are nulled out entirely, not just short-circuited) for the whole
  time any annotation shape is being drawn, and takes effect on the very
  next gesture even if `drawMode` changes with no other rebuild in between.
* Fixed: `SvsFile.readInfo()`/`readAllTags()`/`readTags()` could throw (or,
  for a corrupted `count` field, attempt a multi-gigabyte read) if any tag
  anywhere in the file had an unrecognized TIFF field type — aborting the
  entire "best-effort full dump" over one bad tag. Both now surface as a
  short `<unreadable: ...>` placeholder for that one tag instead.
* Fixed: concurrent `DiskTileCache.put()` calls for different tiles (routine
  during fast pan/zoom, since decoded tiles persist to disk unawaited) could
  race on the shared byte-budget accounting and eviction, letting the cache
  temporarily grow past `maxBytes` by more than the documented
  single-oversized-tile allowance. The accounting/eviction half of `put` is
  now serialized against itself.
* `exportSvsRegionAsSvs` now builds the pyramid (downsampling, JPEG
  encoding, the BigTIFF write) on a background isolate instead of blocking
  the calling isolate — previously a large crop could freeze the UI for
  the whole encode.
* `LodController` no longer persists prefetch-margin tiles (only ever
  fetched speculatively, not yet on screen) to the disk cache — only tiles
  actually visible when decoded are, roughly halving disk I/O during fast
  panning.
* Internal: `TileCache` and `DiskTileCache` now share their LRU eviction
  policy (`pickEvictions`) instead of maintaining two independent copies of
  the same algorithm.

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
