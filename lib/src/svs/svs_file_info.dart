import 'dart:typed_data';

import '../tiff/tiff_tag_names.dart';
import 'svs_metadata.dart';

/// Every TIFF tag on one IFD, decoded — see [TiffIfd.readAllValues] for how
/// each value is decoded. In [SvsFileInfo.levels], [index] is the pyramid
/// level index (`SvsLevel.index`); in [SvsFileInfo.associatedImages], it's
/// the raw IFD index within the file (`SvsAssociatedImage.ifdIndex`).
class SvsIfdInfo {
  final int index;
  final Map<int, Object> tags;

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
  final String path;
  final bool isBigTiff;
  final Endian byteOrder;
  final SvsMetadata metadata;
  final List<SvsIfdInfo> levels;
  final List<SvsIfdInfo> associatedImages;

  const SvsFileInfo({
    required this.path,
    required this.isBigTiff,
    required this.byteOrder,
    required this.metadata,
    required this.levels,
    required this.associatedImages,
  });
}
