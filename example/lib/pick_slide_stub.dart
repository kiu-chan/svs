import 'package:svs/svs.dart';

/// Only the web picks slides this way — native platforms open a path with
/// `SvsFile.open` instead.
Future<RandomAccessByteSource?> pickSlideSource() =>
    throw UnsupportedError('pickSlideSource is only available on the web');
