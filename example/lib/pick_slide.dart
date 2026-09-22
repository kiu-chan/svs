// The web picker needs package:web (dart:js_interop), which only compiles
// for the web — every other platform gets the stub.
export 'pick_slide_stub.dart'
    if (dart.library.js_interop) 'pick_slide_web.dart';
