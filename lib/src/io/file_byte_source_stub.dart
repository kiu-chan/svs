import 'byte_source.dart';

Future<RandomAccessByteSource> openFileByteSource(String path) {
  throw UnsupportedError(
    'Opening an SvsFile by filesystem path is not supported on this '
    'platform (e.g. the web, which has no filesystem). Use '
    'SvsFile.openBytes(bytes) instead.',
  );
}
