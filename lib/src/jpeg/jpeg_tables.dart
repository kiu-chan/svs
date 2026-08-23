import 'dart:typed_data';

const List<int> _soi = [0xFF, 0xD8];
const List<int> _eoi = [0xFF, 0xD9];

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
