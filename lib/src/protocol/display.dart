// QR display-size fitting against the viewport.
//
// Ported from shared/display.ts.

import 'dart:math' as math;

double fitQrDisplaySize(
  int viewportWidth,
  int viewportHeight,
  int containerWidth,
  int requestedSize, [
  int horizontalChrome = 0,
]) {
  final viewportBudget = 0.9 * math.min(viewportWidth, viewportHeight);
  final containerBudget = math.max(1, containerWidth - horizontalChrome);
  return math.max(
    1.0,
    math.min(
      viewportBudget,
      math.min(containerBudget.toDouble(), requestedSize.toDouble()),
    ),
  );
}
