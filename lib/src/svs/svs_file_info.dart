import 'dart:typed_data';

import '../tiff/tiff_tag_names.dart';
import 'svs_metadata.dart';

/// Every TIFF tag on one IFD, decoded — see `TiffIfd.readAllValues` for how
/// each value is decoded. In [SvsFileInfo.levels], [index] is the pyramid
/// level index (`SvsLevel.index`); in [SvsFileInfo.associatedImages], it's
/// the raw IFD index within the file (`SvsAssociatedImage.ifdIndex`).
class SvsIfdInfo {
  /// Which IFD this is — a pyramid level index or a raw IFD index,
  /// depending on which list it came from.
  final int index;

  /// The IFD's tags, keyed by raw TIFF tag ID; [namedTags] gives the same
  /// values under readable names.
  final Map<int, Object> tags;

  /// Creates a dump of one IFD's decoded tags.
  const SvsIfdInfo({required this.index, required this.tags});

  /// [tags], keyed by human-readable name ([tiffTagName]) instead of raw
  /// TIFF tag ID — for presenting a dump to a person.
  Map<String, Object> get namedTags => {
    for (final entry in tags.entries) tiffTagName(entry.key): entry.value,
  };
}

/// A full structured dump of an open [SvsFile]: every TIFF tag of every
/// pyramid level and associated image, alongside the file's own container
/// facts (BigTIFF or classic, byte order) and its already-parsed Aperio
/// [metadata]. Built by [SvsFile.readInfo] — the "full info" one-call
/// counterpart to the fine-grained accessors already on [SvsFile],
/// [SvsLevel], and [SvsAssociatedImage] (dimensions, geometry,
/// `metadata.raw`, [SvsLevel.readTags], [SvsAssociatedImage.readTags]) for
/// callers that only need a specific field.
class SvsFileInfo {
  /// The file's path, or null if it was opened via `SvsFile.openBytes` or
  /// `SvsFile.openSource`.
  final String? path;

  /// Whether the file uses BigTIFF's 64-bit offsets rather than classic
  /// TIFF's 32-bit ones.
  final bool isBigTiff;

  /// The byte order the file's own fields are stored in, as its header
  /// declares.
  final Endian byteOrder;

  /// The slide's parsed Aperio metadata, the same object [SvsFile.metadata]
  /// holds.
  final SvsMetadata metadata;

  /// One entry per pyramid level, finest first, each keyed by its pyramid
  /// level index.
  final List<SvsIfdInfo> levels;

  /// One entry per associated image, each keyed by its raw IFD index within
  /// the file.
  final List<SvsIfdInfo> associatedImages;

  /// Creates a dump of a whole file; [SvsFile.readInfo] builds one from an
  /// open slide.
  const SvsFileInfo({
    required this.path,
    required this.isBigTiff,
    required this.byteOrder,
    required this.metadata,
    required this.levels,
    required this.associatedImages,
  });
}
