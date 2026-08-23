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
  final double? mppX;
  final double? mppY;
  final int? appMag;

  /// Every `key = value` pair found, keyed exactly as written in the file
  /// (e.g. `'AppMag'`, `'MPP'`, `'Left'`, `'Top'`), for callers that want a
  /// field this class doesn't surface directly.
  final Map<String, String> raw;

  const SvsMetadata({this.mppX, this.mppY, this.appMag, required this.raw});

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
    return SvsMetadata(mppX: mpp, mppY: mpp, appMag: int.tryParse(raw['AppMag'] ?? ''), raw: raw);
  }
}
