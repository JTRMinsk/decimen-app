// Paint a QR module matrix into a pixel buffer, quiet zone included.
//
// Pure so it can be golden-tested without Flutter: the pixels are RGBA bytes
// viewed as one little-endian u32 per pixel.
//
// Ported from shared/qr-raster.ts.

import 'dart:typed_data';

const int _white = 0xffffffff;
const int _black = 0xff000000; // opaque black: alpha in the high byte, little-endian

class QrRaster {
  /// Pixels per side: moduleCount + 2 × margin.
  final int size;

  /// One u32 per pixel.
  final Uint32List pixels;
  QrRaster(this.size, this.pixels);
}

/// `modules` is row-major, non-zero = dark.
QrRaster rasterizeQr(int moduleCount, List<int> modules, int margin) {
  final size = moduleCount + 2 * margin;
  final pixels = Uint32List(size * size);
  pixels.fillRange(0, pixels.length, _white);
  for (int y = 0; y < moduleCount; y++) {
    final row = (y + margin) * size + margin;
    final src = y * moduleCount;
    for (int x = 0; x < moduleCount; x++) {
      if (modules[src + x] != 0) pixels[row + x] = _black;
    }
  }
  return QrRaster(size, pixels);
}
