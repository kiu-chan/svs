// `rebuildSvsPyramidToFile`/`rebuildSvsPyramidInPlace` both need a real
// filesystem (a `dart:io` `File` to write/rename, in the latter case a path
// to overwrite) — neither exists on this platform (e.g. the web), so they
// simply aren't declared here. Code that references them on this platform
// fails to compile, the same as using `dart:io` directly would. Use
// `rebuildSvsPyramidToSink` instead (on the web, with a
// `FileSystemWritableByteSink`), or the byte-returning `rebuildSvsPyramid`.
