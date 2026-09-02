// `rebuildSvsPyramidToFile`/`rebuildSvsPyramidInPlace` both need a real
// filesystem (a `dart:io` `File` to write/rename, in the latter case a path
// to overwrite) — neither exists on this platform (e.g. the web), so they
// simply aren't declared here. Code that references them on this platform
// fails to compile, the same as using `dart:io` directly would. Use the
// byte-returning `rebuildSvsPyramid` instead, together with a platform-
// appropriate way to save the bytes (e.g. a browser download on web).
