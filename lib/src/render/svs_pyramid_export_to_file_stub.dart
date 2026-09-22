// `exportSvsRegionAsSvsToFile`/`exportSvsRegionAsSvsPreservingLevelsToFile`
// return `dart:io`'s `File`, a type that doesn't exist on this platform (e.g.
// the web, which has no filesystem) — so they simply aren't declared here.
// Code that references them on this platform fails to compile, the same as
// using `dart:io` directly would. Use the `*ToSink` siblings instead (on the
// web, with a `FileSystemWritableByteSink`), or the byte-returning
// `exportSvsRegionAsSvs`/`exportSvsRegionAsSvsPreservingLevels`.
