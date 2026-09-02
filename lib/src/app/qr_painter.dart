// Paints a QR module matrix with a quiet-zone margin. One module is painted at
// `size / (moduleCount + 2*margin)` so the code is a crisp block matrix at any
// display size (no anti-aliasing blur between modules).

import 'dart:typed_data';

import 'package:flutter/material.dart';

class QrPainter extends CustomPainter {
  final Uint8List modules;
  final int moduleCount;
  final int margin;

  QrPainter({
    required this.modules,
    required this.moduleCount,
    this.margin = 4,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final total = moduleCount + 2 * margin;
    // The paint box is square by construction; guard against a non-square one.
    final side = size.shortestSide;
    final moduleSize = side / total;
    final origin = Offset((size.width - side) / 2, (size.height - side) / 2);

    final white = Paint()..color = const Color(0xFFFFFFFF);
    final dark = Paint()..color = const Color(0xFF000000);

    canvas.drawRect(Offset.zero & size, white);

    for (int r = 0; r < moduleCount; r++) {
      final row = r * moduleCount;
      for (int c = 0; c < moduleCount; c++) {
        if (modules[row + c] != 0) {
          final left = origin.dx + (c + margin) * moduleSize;
          final top = origin.dy + (r + margin) * moduleSize;
          canvas.drawRect(
            Rect.fromLTWH(left, top, moduleSize, moduleSize),
            dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant QrPainter oldDelegate) =>
      oldDelegate.modules != modules || oldDelegate.moduleCount != moduleCount;
}
