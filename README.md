# svs

A Flutter library for displaying Aperio SVS (whole-slide image) files.

SVS is a pyramidal, tiled TIFF-based format used to store gigapixel
whole-slide microscopy/pathology images. `svs` reads the pyramid directly
and streams only the tiles the current viewport needs — the full image is
never loaded into memory, however large the slide.

## Features

* **Pan & zoom viewer** (`SvsImageView`) with a minimap, zoom percentage,
  and a physical scale bar (µm/mm, derived from the slide's own
  microns-per-pixel metadata).
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
* **Region cropping** (`readSvsRegion`): decode an arbitrary rectangle of any
  pyramid level to a single composited image, without loading the whole
  level.
* Memory-pressure aware tile cache, and active cancellation of in-flight
  tile requests once they scroll out of view.

## Getting started

```yaml
dependencies:
  svs: ^0.1.0
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
HUD on its own — no further wiring needed.

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
