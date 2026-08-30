// `exportSvsRegionAsSvsToFile`/`exportSvsRegionAsSvsPreservingLevelsToFile`
// return `dart:io`'s `File`, a type that doesn't exist on this platform (e.g.
// the web, which has no filesystem) — so they simply aren't declared here.
// Code that references them on this platform fails to compile, the same as
// using `dart:io` directly would. Use the byte-returning siblings
// (`exportSvsRegionAsSvs`/`exportSvsRegionAsSvsPreservingLevels`) instead,
// together with a platform-appropriate way to save the bytes (e.g. a browser
// download on web).
