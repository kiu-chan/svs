// The messages the web codec worker (codec_worker_main.dart) and its pool
// (codec_worker_pool.dart) exchange: plain JS objects keyed by these names,
// with pixel and codestream buffers transferred rather than copied.

/// Request fields.
const opField = 'op';
const idField = 'id';

/// Decode a JPEG2000 codestream: [bytesField], [reduceField].
const opDecodeJ2k = 'decodeJ2k';

/// Encode a band of pyramid tiles: [pixelsField] (RGBA), [widthField],
/// [heightField], [tileWidthField], [tileLengthField], [jpeg2000Field],
/// [qualityField], [ratioField]. Replies with [tilesField].
const opEncodeTiles = 'encodeTiles';

/// Encode a flat image: [pixelsField] (RGBA), [widthField], [heightField],
/// [formatField] (an `SvsImageFormat` index), [qualityField]. Replies with
/// [bytesField].
const opEncodeImage = 'encodeImage';

const bytesField = 'bytes';
const reduceField = 'reduce';
const pixelsField = 'pixels';
const widthField = 'width';
const heightField = 'height';
const componentsField = 'components';
const tileWidthField = 'tileWidth';
const tileLengthField = 'tileLength';
const jpeg2000Field = 'jpeg2000';
const qualityField = 'quality';
const ratioField = 'ratio';
const formatField = 'format';
const tilesField = 'tiles';

/// Set on a reply instead of its result when the request failed:
/// [errorField] the message, [errorKindField] which exception it was.
const errorField = 'error';
const errorKindField = 'errorKind';
const errorKindJ2kDecode = 'j2kDecode';
const errorKindJ2kEncode = 'j2kEncode';
const errorKindArgument = 'argument';
const errorKindOther = 'other';
