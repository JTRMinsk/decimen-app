// QR generation for the sender, wrapping the pure-Dart `qr` package.
//
// Frames are encoded in byte mode (the same mode the web sender's `qrcode`
// library uses), at error-correction level L. The mask pattern is pinned to 4,
// matching the reference's `maskPattern: 4` — skipping the 8-way mask
// evaluation is ~4× faster, and the declared mask is irrelevant to any decoder.

import 'dart:typed_data';

import 'package:qr/qr.dart';

class QrMatrix {
  /// Modules per side (excluding quiet zone).
  final int moduleCount;

  /// Row-major module bits: 1 = dark, 0 = light.
  final Uint8List modules;

  QrMatrix(this.moduleCount, this.modules);
}

QrMatrix encodeQrMatrix(Uint8List bytes) {
  final payload = QrPayload.fromTypedData(bytes);
  final code = QrCode(
    payload: payload,
    errorCorrectLevel: QrErrorCorrectLevel.low,
  );
  final image = QrImage.withMaskPattern(code, 4);
  final n = image.moduleCount;
  final modules = Uint8List(n * n);
  for (int r = 0; r < n; r++) {
    for (int c = 0; c < n; c++) {
      modules[r * n + c] = image.isDark(r, c) ? 1 : 0;
    }
  }
  return QrMatrix(n, modules);
}
