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
