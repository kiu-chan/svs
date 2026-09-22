import 'dart:io';

/// FNV-1a over the contents of [paths] (relative to the package root), in
/// order — enough to notice a generated file has gone stale.
String sourceHash(List<String> paths) {
  var hash = 0x811C9DC5;
  for (final path in paths) {
    for (final byte in [
      ...path.codeUnits,
      0,
      ...File(path).readAsBytesSync(),
    ]) {
      hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
