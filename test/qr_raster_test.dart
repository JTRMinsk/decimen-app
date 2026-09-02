// Ported verbatim from tests/qr-raster.test.ts.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:decimen_app/src/protocol/qr_raster.dart';

const int white = 0xffffffff;
const int black = 0xff000000;

void main() {
  test('a single dark module with no margin is one black pixel', () {
    final r = rasterizeQr(1, [1], 0);
    expect(r.size, 1);
    expect(r.pixels.toList(), [black]);
  });

  test('the margin surrounds the modules with white on every side', () {
    final r = rasterizeQr(1, [1], 2);
    expect(r.size, 5);
    for (int y = 0; y < r.size; y++) {
      for (int x = 0; x < r.size; x++) {
        final expected = x == 2 && y == 2 ? black : white;
        expect(r.pixels[y * r.size + x], expected, reason: 'pixel ($x,$y)');
      }
    }
  });

  test('modules map row-major and non-zero means dark', () {
    final r = rasterizeQr(2, [1, 0, 0, 1], 0);
    expect(r.size, 2);
    expect(r.pixels.toList(), [black, white, white, black]);
  });

  test('an all-light matrix rasterizes to all white', () {
    final r = rasterizeQr(3, Uint8List(9), 1);
    expect(r.size, 5);
    expect(r.pixels.every((p) => p == white), isTrue);
  });

  test('pixel values are the RGBA bytes an ImageData buffer expects', () {
    final r = rasterizeQr(1, [1], 1);
    final bytes = Uint8List.view(r.pixels.buffer);
    final center = 4 * (1 * 3 + 1);
    expect(bytes.sublist(center, center + 4), [0, 0, 0, 255]);
    expect(bytes.sublist(0, 4), [255, 255, 255, 255]);
  });
}
