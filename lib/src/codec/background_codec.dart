// Where the CPU-heavy codec work runs: natively, where the caller already
// is (a worker isolate for viewer tiles; flat-image encodes get their own
// isolate); on the web, a Web Worker (see web/codec_worker_pool.dart), with
// the calling thread as the fallback when a page can't run one.
export 'background_codec_io.dart'
    if (dart.library.js_interop) 'background_codec_web.dart';
