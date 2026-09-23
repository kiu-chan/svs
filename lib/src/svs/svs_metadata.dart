/// Parsed form of an Aperio `ImageDescription` field. The raw string looks
/// like:
///
/// ```
/// Aperio Image Library v11.2.1
/// 46920x33014 [0,100 46000x32914] (256x256) JPEG/RGB Q=30|AppMag = 20|MPP = 0.4990|...
/// ```
///
/// — a free-text header, then a `|`-separated list of `key = value` pairs.
/// Only the header is not a pair; everything after the first `|` is.
class SvsMetadata {
  /// Microns per pixel across level 0, from the `MPP` field, or null when
  /// the slide does not state one.
  final double? mppX;

  /// Microns per pixel down level 0. Aperio writes a single `MPP` for both
  /// axes, so [SvsMetadata.parse] gives this the same value as [mppX];
  /// the two are kept apart for slides whose pixels are not square.
  final double? mppY;

  /// The objective magnification the slide was scanned at, from `AppMag`
  /// — 20 or 40 on most Aperio slides — or null when absent.
  final int? appMag;

  /// Every `key = value` pair found, keyed exactly as written in the file
  /// (e.g. `'AppMag'`, `'MPP'`, `'Left'`, `'Top'`), for callers that want a
  /// field this class doesn't surface directly.
  final Map<String, String> raw;

  /// Creates metadata directly, rather than by parsing a slide's
  /// description.
  const SvsMetadata({this.mppX, this.mppY, this.appMag, required this.raw});

  /// Parses an Aperio `ImageDescription` into its fields.
  ///
  /// Anything unparseable is skipped rather than thrown over: a null or
  /// empty description, or one with no `key = value` pairs, yields metadata
  /// whose fields are null and whose [raw] is empty.
  factory SvsMetadata.parse(String? imageDescription) {
    if (imageDescription == null || imageDescription.isEmpty) {
      return const SvsMetadata(raw: {});
    }
    final segments = imageDescription.split('|');
    final raw = <String, String>{};
    for (final segment in segments.skip(1)) {
      final eq = segment.indexOf('=');
      if (eq == -1) continue;
      final key = segment.substring(0, eq).trim();
      final value = segment.substring(eq + 1).trim();
      if (key.isNotEmpty) raw[key] = value;
    }
    final mpp = double.tryParse(raw['MPP'] ?? '');
    return SvsMetadata(
      mppX: mpp,
      mppY: mpp,
      appMag: int.tryParse(raw['AppMag'] ?? ''),
      raw: raw,
    );
  }
}
