import 'package:svs/src/codec/jpeg2000/j2k_decoder.dart';

/// A decoded image's size, component count and Adler-32 of its samples —
/// exact under both the VM's and JS's integer semantics.
String fingerprint(J2kImage image) {
  var a = 1, b = 0;
  for (final v in image.pixels) {
    a = (a + v) % 65521;
    b = (b + a) % 65521;
  }
  return '${image.width}x${image.height}x${image.numComponents}:'
      '${(b * 65536 + a).toRadixString(16)}';
}
