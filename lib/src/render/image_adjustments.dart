import 'dart:typed_data';
import 'dart:ui' as ui;

/// Brightness/contrast/shadow/highlight adjustment, applied identically to
/// both a live [SvsImageView] (via [toColorFilter], GPU-accelerated) and an
/// exported image (via [applyToRgba], applied to the decoded pixels before
/// encoding) — the same parameters always produce the same result in both
/// places, since both derive from the same [_affine] map.
///
/// All four parameters are nominally `-1..1`, `0` meaning "no change"
/// ([none], the default everywhere in this package). They combine into a
/// single per-channel affine transform (`out = slope * in + intercept`) —
/// deliberately linear rather than a true non-linear tone curve, since a
/// curve isn't representable as one GPU `ColorFilter.matrix` and
/// reprocessing every decoded tile's pixels on every slider frame isn't
/// practical without fragment shaders. Concretely:
///
/// * [shadows] / [highlights] shift the *output* black/white point (a
///   standard "Levels" control): positive [shadows] raises the black point
///   (brightens dark regions, up to 30% gray at `1.0`); positive
///   [highlights] lowers the white point (protects/dims bright regions, down
///   to 70% gray at `1.0`). Because the map is linear, these shift *every*
///   pixel's value, not just the ones actually in shadow/highlight — a
///   negative [shadows] or [highlights] behaves similarly to [brightness].
/// * [contrast] scales around mid-gray (0.5); `1.0` doubles it, `-1.0`
///   flattens the image to flat mid-gray.
/// * [brightness] shifts the whole image uniformly, up to `±50%` of the
///   value range at `±1.0`.
///
/// Alpha is left untouched everywhere.
class SvsImageAdjustments {
  final double brightness;
  final double contrast;
  final double shadows;
  final double highlights;

  const SvsImageAdjustments({
    this.brightness = 0,
    this.contrast = 0,
    this.shadows = 0,
    this.highlights = 0,
  });

  /// No adjustment — the default for [SvsImageView.adjustments] and every
  /// export function's `adjustments` parameter.
  static const none = SvsImageAdjustments();

  bool get isIdentity =>
      brightness == 0 && contrast == 0 && shadows == 0 && highlights == 0;

  /// The single per-channel affine map (`out = slope * in + intercept`, both
  /// already scaled for 0-255 byte space) all four parameters combine into.
  (double slope, double intercept) get _affine {
    // *Output* black/white point (unlike an *input* black/white point, this
    // lifts/protects rather than crushes): in=0 lands at outBlack (not 0)
    // and in=1 lands at outWhite (not 1).
    final outBlack = shadows.clamp(-1.0, 1.0) * 0.3;
    final outWhite = 1.0 - highlights.clamp(-1.0, 1.0) * 0.3;
    final levelsSlope = outWhite - outBlack;
    final levelsIntercept = outBlack;

    final contrastFactor = 1.0 + contrast.clamp(-1.0, 1.0);
    final brightnessShift = brightness.clamp(-1.0, 1.0) * 0.5;

    final slope = levelsSlope * contrastFactor;
    final intercept =
        (levelsIntercept - 0.5) * contrastFactor + 0.5 + brightnessShift;
    return (slope, intercept * 255);
  }

  /// The `ColorFilter.matrix` equivalent of [_affine], or `null` when
  /// [isIdentity] (so a painter can skip setting a filter entirely).
  ui.ColorFilter? toColorFilter() {
    if (isIdentity) return null;
    final (slope, intercept) = _affine;
    return ui.ColorFilter.matrix(<double>[
      slope, 0, 0, 0, intercept, //
      0, slope, 0, 0, intercept, //
      0, 0, slope, 0, intercept, //
      0, 0, 0, 1, 0,
    ]);
  }

  /// Applies [_affine] in place to tightly-packed RGBA8888 [rgba] — alpha
  /// (every 4th byte) is left untouched. A no-op when [isIdentity].
  void applyToRgba(Uint8List rgba) {
    if (isIdentity) return;
    final (slope, intercept) = _affine;
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = (rgba[i] * slope + intercept).clamp(0, 255).round();
      rgba[i + 1] = (rgba[i + 1] * slope + intercept).clamp(0, 255).round();
      rgba[i + 2] = (rgba[i + 2] * slope + intercept).clamp(0, 255).round();
    }
  }
}
