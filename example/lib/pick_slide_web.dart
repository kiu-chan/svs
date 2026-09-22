import 'dart:async';
import 'dart:js_interop';

import 'package:svs/svs.dart';
import 'package:svs/svs_web.dart';
import 'package:web/web.dart' as web;

/// Shows the browser's file picker and returns the chosen slide as a
/// [BlobByteSource] — read a slice at a time as it's viewed, so even a
/// multi-GB slide is never loaded into memory whole. Null if cancelled.
Future<RandomAccessByteSource?> pickSlideSource() {
  final picked = Completer<web.File?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.svs,.tif,.tiff';
  input.onchange = ((web.Event _) {
    picked.complete(input.files?.item(0));
  }).toJS;
  input.oncancel = ((web.Event _) {
    if (!picked.isCompleted) picked.complete(null);
  }).toJS;
  input.click();
  return picked.future.then(
    (file) => file == null ? null : BlobByteSource(file),
  );
}
