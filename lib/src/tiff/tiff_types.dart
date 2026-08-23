import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';

/// TIFF 6.0 / BigTIFF field type IDs — the "Type" half of a directory entry.
abstract final class TiffType {
  static const byte = 1;
  static const ascii = 2;
  static const short = 3;
  static const long = 4;
  static const rational = 5;
  static const sbyte = 6;
  static const undefined = 7;
  static const sshort = 8;
  static const slong = 9;
  static const srational = 10;
  static const float = 11;
  static const double_ = 12;
  static const ifd = 13;

  // BigTIFF additions.
  static const long8 = 16;
  static const slong8 = 17;
  static const ifd8 = 18;
}

/// Size in bytes of a single value of [type].
int tiffTypeSize(int type) {
  switch (type) {
    case TiffType.byte:
    case TiffType.ascii:
    case TiffType.sbyte:
    case TiffType.undefined:
      return 1;
    case TiffType.short:
    case TiffType.sshort:
      return 2;
    case TiffType.long:
    case TiffType.slong:
    case TiffType.float:
    case TiffType.ifd:
      return 4;
    case TiffType.rational:
    case TiffType.srational:
    case TiffType.double_:
    case TiffType.long8:
    case TiffType.slong8:
    case TiffType.ifd8:
      return 8;
  }
  throw SvsFormatException('Unknown TIFF field type: $type');
}

/// Decodes [count] integer values of [type] from [bytes] (BYTE, SHORT, LONG,
/// LONG8 and their signed variants). Throws for non-integer types (RATIONAL,
/// FLOAT, DOUBLE, ASCII) — those have dedicated decoders.
List<int> decodeTiffInts(Uint8List bytes, int type, int count, Endian order) {
  final data = ByteData.sublistView(bytes);
  final size = tiffTypeSize(type);
  final values = List<int>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    final o = i * size;
    values[i] = switch (type) {
      TiffType.byte || TiffType.undefined => data.getUint8(o),
      TiffType.sbyte => data.getInt8(o),
      TiffType.short => data.getUint16(o, order),
      TiffType.sshort => data.getInt16(o, order),
      TiffType.long || TiffType.ifd => data.getUint32(o, order),
      TiffType.slong => data.getInt32(o, order),
      TiffType.long8 || TiffType.ifd8 => data.getUint64(o, order),
      TiffType.slong8 => data.getInt64(o, order),
      _ => throw SvsFormatException('TIFF type $type is not integer-valued'),
    };
  }
  return values;
}

/// Decodes a TIFF ASCII field: NUL-terminated (the terminator is included in
/// the tag's `count`), trimmed here so callers never see it.
String decodeTiffAscii(Uint8List bytes) {
  var end = bytes.length;
  while (end > 0 && bytes[end - 1] == 0) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}

/// Decodes [count] RATIONAL/SRATIONAL values of [type] from [bytes] as
/// (numerator, denominator) pairs — each is two 4-byte ints, unsigned for
/// RATIONAL, signed for SRATIONAL.
List<(int, int)> decodeTiffRationals(
  Uint8List bytes,
  int type,
  int count,
  Endian order,
) {
  if (type != TiffType.rational && type != TiffType.srational) {
    throw SvsFormatException('TIFF type $type is not a rational type');
  }
  final data = ByteData.sublistView(bytes);
  final signed = type == TiffType.srational;
  return List.generate(count, (i) {
    final o = i * 8;
    final num = signed ? data.getInt32(o, order) : data.getUint32(o, order);
    final den = signed
        ? data.getInt32(o + 4, order)
        : data.getUint32(o + 4, order);
    return (num, den);
  });
}

/// Decodes [count] FLOAT/DOUBLE values of [type] from [bytes].
List<double> decodeTiffFloats(
  Uint8List bytes,
  int type,
  int count,
  Endian order,
) {
  final data = ByteData.sublistView(bytes);
  return switch (type) {
    TiffType.float => List.generate(
      count,
      (i) => data.getFloat32(i * 4, order),
    ),
    TiffType.double_ => List.generate(
      count,
      (i) => data.getFloat64(i * 8, order),
    ),
    _ => throw SvsFormatException('TIFF type $type is not a float type'),
  };
}
