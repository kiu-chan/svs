/// Human-readable names for baseline TIFF tag IDs (plus the Aperio-specific
/// ones this package reads — see `svs/aperio_tags.dart`), for presenting a
/// full tag dump to a person rather than a table of bare integers. Not
/// exhaustive — the TIFF tag space is large and mostly vendor-private;
/// unknown IDs fall back to `'Tag<id>'`.
const _tiffTagNames = <int, String>{
  256: 'ImageWidth',
  257: 'ImageLength',
  258: 'BitsPerSample',
  259: 'Compression',
  262: 'PhotometricInterpretation',
  270: 'ImageDescription',
  271: 'Make',
  272: 'Model',
  273: 'StripOffsets',
  274: 'Orientation',
  277: 'SamplesPerPixel',
  278: 'RowsPerStrip',
  279: 'StripByteCounts',
  282: 'XResolution',
  283: 'YResolution',
  284: 'PlanarConfiguration',
  296: 'ResolutionUnit',
  305: 'Software',
  306: 'DateTime',
  315: 'Artist',
  317: 'Predictor',
  318: 'WhitePoint',
  319: 'PrimaryChromaticities',
  320: 'ColorMap',
  322: 'TileWidth',
  323: 'TileLength',
  324: 'TileOffsets',
  325: 'TileByteCounts',
  338: 'ExtraSamples',
  339: 'SampleFormat',
  347: 'JPEGTables',
  700: 'XMP',
  33432: 'Copyright',
  34665: 'ExifIFD',
  34675: 'ICCProfile',
  42112: 'GDAL_METADATA',
};

/// The human-readable name of TIFF tag [id] (e.g. `'ImageWidth'` for `256`),
/// or `'Tag<id>'` if this package doesn't have a name for it.
String tiffTagName(int id) => _tiffTagNames[id] ?? 'Tag$id';
