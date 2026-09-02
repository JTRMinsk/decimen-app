// Ported verbatim from tests/display.test.ts.

import 'package:flutter_test/flutter_test.dart';

import 'package:decimen_app/src/protocol/display.dart';

void main() {
  test('QR display fits inside its container including padding', () {
    expect(fitQrDisplaySize(1440, 1000, 720, 900, 40), 680);
  });

  test('QR display still respects the requested and viewport sizes', () {
    expect(fitQrDisplaySize(1440, 1000, 1200, 600, 40), 600);
    expect(fitQrDisplaySize(390, 844, 366, 900, 40), 326);
  });
}
