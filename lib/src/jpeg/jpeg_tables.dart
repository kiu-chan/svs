import 'dart:typed_data';

const List<int> _soi = [0xFF, 0xD8];
const List<int> _eoi = [0xFF, 0xD9];

/// A 16-byte Adobe APP14 segment declaring `transform=0` (its last byte) —
/// see [forceRgbColorTransform] for what that tells a decoder to do.
/// Structure: marker (FF EE), segment length (00 0E, i.e. 14 — includes
/// itself but not the marker), then the 12-byte payload: the "Adobe"
/// signature, a version word, two flag words, and the transform byte.
const List<int> _adobeRgbSegment = [
  0xFF, 0xEE, // APP14
  0x00, 0x0E, // length = 14
  0x41, 0x64, 0x6F, 0x62, 0x65, // "Adobe"
  0x00, 0x64, // version 100
  0x00, 0x00, // flags0
  0x00, 0x00, // flags1
  0x00, // transform = 0 (RGB, no color transform)
];

/// SVS tiles use TIFF's "new-style JPEG" scheme (`Compression` = 7): each
/// tile is a JPEG scan with its own SOI/EOI but, when the IFD carries a
/// `JPEGTables` tag, no Huffman/quantization tables of its own — those live
/// once per IFD and must be spliced in front of every tile to produce a
/// standalone, independently decodable JPEG stream.
///
/// If [jpegTables] is null or empty (the tag is optional — some encoders
/// embed full tables in every tile), [tileBytes] is assumed to already be
/// a standalone JPEG and is returned unchanged.
Uint8List spliceJpegTile(Uint8List? jpegTables, Uint8List tileBytes) {
  if (jpegTables == null || jpegTables.isEmpty) {
    return tileBytes;
  }

  var tablesEnd = jpegTables.length;
  if (tablesEnd >= 2 &&
      jpegTables[tablesEnd - 2] == _eoi[0] &&
      jpegTables[tablesEnd - 1] == _eoi[1]) {
    tablesEnd -= 2;
  }

  var tileStart = 0;
  if (tileBytes.length >= 2 &&
      tileBytes[0] == _soi[0] &&
      tileBytes[1] == _soi[1]) {
    tileStart = 2;
  }

  final spliced = Uint8List(tablesEnd + (tileBytes.length - tileStart));
  spliced.setRange(0, tablesEnd, jpegTables);
  spliced.setRange(tablesEnd, spliced.length, tileBytes, tileStart);
  return spliced;
}

/// Inserts an Adobe APP14 segment declaring `transform=0` right after
/// [bytes]' SOI marker, so a decoder skips the YCbCr->RGB color transform
/// entirely and hands back the samples untouched.
///
/// Aperio writes some slides' JPEG streams with TIFF
/// `PhotometricInterpretation=RGB` — i.e. literal RGB samples, never
/// YCbCr-encoded — but with no JPEG-level marker declaring that. Lacking
/// one, `dart:ui`'s JPEG codec (Skia, on every platform Flutter supports)
/// assumes YCbCr for an ordinary 3-component frame and applies the
/// transform anyway, corrupting the output — most visibly on bright/
/// desaturated regions (typically most of a slide's background), where the
/// wrongly-applied transform saturates a channel at 0 or 255 and
/// permanently discards the information needed to recover the true sample.
/// That made an earlier approach here (let the wrong decode happen, then
/// invert the transform on the decoded pixels) lossy in exactly the region
/// — near-white background — where slides most need it to be exact.
///
/// The standard, unambiguous way to tell a decoder "these 3 components are
/// literal RGB, not YCbCr" is Adobe's own APP14 marker (the same one
/// Photoshop writes) with its transform byte set to 0 — Skia's JPEG codec
/// honors it. (An alternative, older convention — naming the SOF components
/// ASCII `'R'`,`'G'`,`'B'` instead of the usual `1,2,3` — is what libjpeg
/// itself falls back to guessing from, but Skia's codec doesn't consult it,
/// so it doesn't help here.)
///
/// [bytes] must start with a valid SOI (0xFF 0xD8) — true for anything
/// [spliceJpegTile] produced. No-op (returns [bytes] unchanged) otherwise.
Uint8List forceRgbColorTransform(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != _soi[0] || bytes[1] != _soi[1]) {
    return bytes;
  }
  final out = Uint8List(bytes.length + _adobeRgbSegment.length);
  out.setRange(0, 2, bytes, 0);
  out.setRange(2, 2 + _adobeRgbSegment.length, _adobeRgbSegment);
  out.setRange(2 + _adobeRgbSegment.length, out.length, bytes, 2);
  return out;
}
