import 'dart:math' as math;
import 'dart:typed_data';

/// A tightly packed, row-major raster of 8-bit RGBA pixels — the in-memory
/// shape every encoder and resampling step in the export paths works on.
class RgbaImage {
  final int width;
  final int height;

  /// Exactly `width * height * 4` bytes: R, G, B, A per pixel.
  final Uint8List pixels;

  RgbaImage(this.width, this.height, this.pixels) {
    if (width < 0 || height < 0 || pixels.length != width * height * 4) {
      throw ArgumentError(
        'A ${width}x$height RGBA image needs ${width * height * 4} bytes, '
        'got ${pixels.length}',
      );
    }
  }

  /// A [width]x[height] image with every channel, alpha included, zeroed.
  RgbaImage.blank(this.width, this.height)
    : pixels = Uint8List(width * height * 4);

  /// A copy of the [width]x[height] rectangle at ([x], [y]), which must lie
  /// within this image.
  RgbaImage crop({
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    _checkRect(x, y, width, height);
    final out = Uint8List(width * height * 4);
    final rowBytes = width * 4;
    for (var row = 0; row < height; row++) {
      final from = ((y + row) * this.width + x) * 4;
      out.setRange(row * rowBytes, (row + 1) * rowBytes, pixels, from);
    }
    return RgbaImage(width, height, out);
  }

  /// The RGB channels (alpha dropped) of the [width]x[height] rectangle at
  /// ([x], [y]), placed top-left in an [outWidth]x[outHeight] buffer (the
  /// rectangle's own size by default) whose remainder is black.
  Uint8List rgbBytes({
    required int x,
    required int y,
    required int width,
    required int height,
    int? outWidth,
    int? outHeight,
  }) {
    _checkRect(x, y, width, height);
    final bufferWidth = outWidth ?? width;
    final bufferHeight = outHeight ?? height;
    if (bufferWidth < width || bufferHeight < height) {
      throw ArgumentError(
        'A ${bufferWidth}x$bufferHeight buffer can\'t hold a '
        '${width}x$height rectangle',
      );
    }
    final out = Uint8List(bufferWidth * bufferHeight * 3);
    for (var row = 0; row < height; row++) {
      var from = ((y + row) * this.width + x) * 4;
      var to = row * bufferWidth * 3;
      for (var col = 0; col < width; col++) {
        out[to] = pixels[from];
        out[to + 1] = pixels[from + 1];
        out[to + 2] = pixels[from + 2];
        from += 4;
        to += 3;
      }
    }
    return out;
  }

  /// Resampled to [newWidth]x[newHeight]: each output pixel is the rounded
  /// mean of the source pixels under its footprint (at least one) — a box
  /// filter when shrinking, nearest-neighbor when enlarging.
  RgbaImage resizeAverage(int newWidth, int newHeight) {
    if (newWidth <= 0 || newHeight <= 0 || width == 0 || height == 0) {
      throw ArgumentError(
        'Can\'t resize ${width}x$height to ${newWidth}x$newHeight',
      );
    }
    final scaleX = width / newWidth;
    final scaleY = height / newHeight;
    final spanStart = Int32List(newWidth);
    final spanEnd = Int32List(newWidth);
    for (var ox = 0; ox < newWidth; ox++) {
      final start = math.min((ox * scaleX).floor(), width - 1);
      spanStart[ox] = start;
      spanEnd[ox] = math.max(
        start + 1,
        math.min(((ox + 1) * scaleX).floor(), width),
      );
    }

    final out = Uint8List(newWidth * newHeight * 4);
    var to = 0;
    for (var oy = 0; oy < newHeight; oy++) {
      final y0 = math.min((oy * scaleY).floor(), height - 1);
      final y1 = math.max(y0 + 1, math.min(((oy + 1) * scaleY).floor(), height));
      for (var ox = 0; ox < newWidth; ox++) {
        final x0 = spanStart[ox];
        final x1 = spanEnd[ox];
        var r = 0, g = 0, b = 0, a = 0;
        for (var sy = y0; sy < y1; sy++) {
          var from = (sy * width + x0) * 4;
          for (var sx = x0; sx < x1; sx++) {
            r += pixels[from];
            g += pixels[from + 1];
            b += pixels[from + 2];
            a += pixels[from + 3];
            from += 4;
          }
        }
        final count = (y1 - y0) * (x1 - x0);
        final half = count ~/ 2;
        out[to] = (r + half) ~/ count;
        out[to + 1] = (g + half) ~/ count;
        out[to + 2] = (b + half) ~/ count;
        out[to + 3] = (a + half) ~/ count;
        to += 4;
      }
    }
    return RgbaImage(newWidth, newHeight, out);
  }

  /// Overwrites this image's pixels (alpha included, no blending) with
  /// [source] placed at ([dstX], [dstY]), clipped to this image's bounds.
  void blit(RgbaImage source, {required int dstX, required int dstY}) {
    final left = math.max(0, dstX);
    final top = math.max(0, dstY);
    final right = math.min(width, dstX + source.width);
    final bottom = math.min(height, dstY + source.height);
    if (right <= left || bottom <= top) return;
    final rowBytes = (right - left) * 4;
    for (var y = top; y < bottom; y++) {
      final from = ((y - dstY) * source.width + (left - dstX)) * 4;
      final to = (y * width + left) * 4;
      pixels.setRange(to, to + rowBytes, source.pixels, from);
    }
  }

  void _checkRect(int x, int y, int w, int h) {
    if (x < 0 || y < 0 || w < 0 || h < 0 || x + w > width || y + h > height) {
      throw RangeError(
        'Rectangle ($x, $y) ${w}x$h lies outside a ${width}x$height image',
      );
    }
  }
}
