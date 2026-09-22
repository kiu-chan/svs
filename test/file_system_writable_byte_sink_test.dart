// FileSystemWritableByteSink only exists on the web (it wraps a DOM
// FileSystemWritableFileStream), so this runs under
// `flutter test --platform chrome` only, writing to the origin private file
// system.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/render/svs_pyramid_export.dart';
import 'package:svs/src/svs/svs_file.dart';
import 'package:svs/svs_web.dart';

import 'helpers/jpeg_slide_builder.dart';

@JS('navigator.storage')
external _StorageManager get _storage;

extension type _StorageManager._(JSObject _) implements JSObject {
  external JSPromise<_Directory> getDirectory();
}

extension type _Directory._(JSObject _) implements JSObject {
  external JSPromise<_FileHandle> getFileHandle(
    String name,
    _GetFileOptions options,
  );
  external JSPromise<JSAny?> removeEntry(String name);
}

extension type _GetFileOptions._(JSObject _) implements JSObject {
  external factory _GetFileOptions({bool create});
}

extension type _FileHandle._(JSObject _) implements JSObject {
  external JSPromise<JSObject> createWritable();
  external JSPromise<JSObject> getFile();
}

void main() {
  late _Directory root;
  late _FileHandle handle;
  var fileIndex = 0;

  setUp(() async {
    root = await _storage.getDirectory().toDart;
    final name = 'sink_test_${fileIndex++}.bin';
    handle = await root
        .getFileHandle(name, _GetFileOptions(create: true))
        .toDart;
    addTearDown(() => root.removeEntry(name).toDart);
  });

  Future<FileSystemWritableByteSink> openSink() async =>
      FileSystemWritableByteSink(await handle.createWritable().toDart);

  Future<Uint8List> fileBytes() async {
    final source = BlobByteSource(await handle.getFile().toDart);
    return source.readRange(0, source.length);
  }

  test('writes sequentially and overwrites after seeking back', () async {
    final sink = await openSink();
    await sink.writeFrom([1, 2, 3, 4, 5]);
    await sink.setPosition(1);
    await sink.writeFrom([9, 9]);
    expect(await sink.position(), 3);
    await sink.setPosition(5);
    await sink.writeFrom([6]);
    await sink.close();

    expect(await fileBytes(), [1, 9, 9, 4, 5, 6]);
  });

  test('handles writes around and past its 4 MB chunk size', () async {
    const mb = 1024 * 1024;
    final small = Uint8List(100 * 1024);
    final big = Uint8List(5 * mb);
    for (var i = 0; i < big.length; i++) {
      big[i] = i % 251;
    }

    final sink = await openSink();
    var written = 0;
    for (var i = 0; i < 50; i++) {
      small.fillRange(0, small.length, i);
      await sink.writeFrom(small);
      written += small.length;
    }
    await sink.writeFrom(big);
    await sink.setPosition(0);
    await sink.writeFrom([200]);
    await sink.close();

    final bytes = await fileBytes();
    expect(bytes, hasLength(written + big.length));
    expect(bytes[0], 200);
    expect(bytes[1], 0);
    expect(bytes[small.length], 1);
    expect(bytes[49 * small.length + 1], 49);
    expect(bytes.sublist(written, written + 1000), big.sublist(0, 1000));
    expect(bytes.sublist(bytes.length - 10), big.sublist(big.length - 10));
  });

  test('abort leaves the file as it was', () async {
    final first = await openSink();
    await first.writeFrom([7, 7, 7]);
    await first.close();

    final second = await openSink();
    await second.writeFrom(Uint8List(5 * 1024 * 1024));
    await second.abort();

    expect(await fileBytes(), [7, 7, 7]);
  });

  test('rejects writes once closed', () async {
    final sink = await openSink();
    await sink.close();
    await sink.close(); // idempotent
    await sink.abort(); // no-op after close
    await expectLater(sink.writeFrom([1]), throwsStateError);
  });

  test('rejects an object that is not a FileSystemWritableFileStream', () {
    expect(() => FileSystemWritableByteSink(JSObject()), throwsArgumentError);
  });

  test('an export streamed into it matches the in-memory export', () async {
    final svs = await SvsFile.openBytes(
      buildJpegTiledSlide(width: 600, height: 400),
    );
    addTearDown(svs.close);
    final expected = await exportSvsRegionAsSvs(
      svs,
      level: 0,
      x: 0,
      y: 0,
      width: 600,
      height: 400,
      tileSize: 128,
    );

    final sink = await openSink();
    await exportSvsRegionAsSvsToSink(
      svs,
      sink: sink,
      level: 0,
      x: 0,
      y: 0,
      width: 600,
      height: 400,
      tileSize: 128,
    );
    await sink.close();

    expect(await fileBytes(), expected);
    final exported = await SvsFile.openSource(
      BlobByteSource(await handle.getFile().toDart),
    );
    addTearDown(exported.close);
    expect(exported.levels, hasLength(4));
  });
}
