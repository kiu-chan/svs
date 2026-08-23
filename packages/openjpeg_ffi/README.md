# openjpeg_ffi

Pure-Dart-package-shaped bindings to [OpenJPEG](https://github.com/uclouvain/openjpeg)
for decoding raw JPEG2000 (`.j2k`) codestreams, via `dart:ffi` and Dart's
native-assets build hooks — no manual native setup required by consumers.

Built for [`svs`](../svs), to decode JPEG2000-compressed Aperio SVS whole-slide
pyramid tiles, but has no SVS/TIFF knowledge of its own — it just decodes a
J2K codestream to raw pixels.

## Usage

```dart
import 'package:openjpeg_ffi/openjpeg_ffi.dart';

final image = decodeJ2k(bytes); // Uint8List of a raw J2K codestream (starts FF4F)
print('${image.width}x${image.height}, ${image.numComponents} components');
```

`decodeJ2k` is synchronous and blocking (like any FFI call), but — unlike
`dart:ui`'s image codecs — has no main-isolate restriction, so it's safe to
call from a background isolate to keep decode work off the UI thread.

Throws [Jp2kDecodeException] if the codestream is malformed or otherwise
fails to decode.

## Only raw J2K codestreams

This decodes the raw codestream format (`FF4F` SOC marker), not the
box-structured `.jp2` file format — which is what TIFF/SVS tile storage
uses. Feeding it a `.jp2` file will fail to decode.

## Project structure

* `src/openjpeg_ffi.h`/`.c` — the shim: a small, deliberately narrow C API
  (`jp2k_decode`/`jp2k_free_result`) wrapping OpenJPEG's own much larger
  surface, so only a handful of functions ever need Dart bindings.
* `src/vendor/openjp2/` — OpenJPEG 2.5.4's core decode library (`src/lib/openjp2/`
  upstream), vendored as source and compiled fresh by `hook/build.dart` on
  every platform — see `OPENJPEG_LICENSE` in that directory (BSD-2-Clause).
  `opj_config.h`/`opj_config_private.h` are hand-resolved static headers
  (see their own comments) rather than CMake-generated, since this package
  bypasses OpenJPEG's own CMake build entirely.
* `hook/build.dart` — compiles the shim plus every vendored `.c` file via
  `package:native_toolchain_c`'s `CBuilder`, targeting whatever platform is
  building (macOS/iOS/Android/Windows/Linux — no per-platform code needed).
* `lib/openjpeg_ffi.dart` — the public Dart API (`decodeJ2k`, `Jp2kImage`,
  `Jp2kDecodeException`). `lib/openjpeg_ffi_bindings_generated.dart` is
  `ffigen`-generated from `src/openjpeg_ffi.h` — regenerate via
  `dart run ffigen --config ffigen.yaml` if the shim header changes.
* `test/fixtures/` — a real J2K tile extracted from an Aperio sample file,
  plus its Pillow-computed expected decode, for a fast pixel-exact
  regression test that needs no large sample `.svs` file.
