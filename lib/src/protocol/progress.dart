// Progress estimation and fountain-overhead model.
//
// Ported from shared/progress.ts.

import 'dart:math' as math;

/// Distinct frames per source block a stream needs.
///
/// The v2 systematic carousel needs exactly 1.00 at zero loss. The 2% margin
/// keeps the bar from over-promising on the odd dropped frame.
double expectedFountainOverhead(int sourceBlocks) {
  return sourceBlocks <= 1 ? 1 : 1.02;
}

class TransferProgressEstimate {
  final double fraction;
  final int expectedFrames;
  final double? etaSeconds;
  final String phase; // "collecting" | "decoding"
  TransferProgressEstimate({
    required this.fraction,
    required this.expectedFrames,
    required this.etaSeconds,
    required this.phase,
  });
}

TransferProgressEstimate estimateTransferProgress(
  int sourceBlocks,
  int uniqueFrames,
  double elapsedSeconds, [
  int solvedBlocks = 0,
]) {
  final minimumFrames = math.max(1, sourceBlocks);
  final expectedFrames = math.max(
    minimumFrames + 1,
    (minimumFrames * expectedFountainOverhead(minimumFrames)).ceil(),
  );
  final expectedRedundancy = expectedFrames - minimumFrames;

  double frameFraction;
  if (uniqueFrames < minimumFrames) {
    frameFraction = 0.86 * (uniqueFrames / minimumFrames);
  } else if (uniqueFrames <= expectedFrames) {
    frameFraction =
        0.86 + 0.1 * ((uniqueFrames - minimumFrames) / expectedRedundancy);
  } else {
    final extra = (uniqueFrames - expectedFrames) / expectedRedundancy;
    frameFraction = 0.96 + 0.03 * (1 - math.exp(-extra));
  }
  // Frames PROMISE; blocks DELIVER. Once blocks are being solved, the frame
  // baseline may lead them by at most 12% of the stream.
  if (solvedBlocks > 0) {
    final lead = 0.12 * minimumFrames;
    frameFraction = math.min(
      frameFraction,
      0.86 * math.min(1, (solvedBlocks + lead) / minimumFrames),
    );
  }
  final decodedFraction = 0.99 * math.min(1, solvedBlocks / minimumFrames);
  final fraction = math.min(0.99, math.max(frameFraction, decodedFraction));
  final phase = uniqueFrames < minimumFrames ? 'collecting' : 'decoding';
  final rate = elapsedSeconds > 0 ? uniqueFrames / elapsedSeconds : 0.0;

  final overshoot = uniqueFrames - expectedFrames;
  final step = math.max(expectedRedundancy, (minimumFrames / 10).ceil());
  final target = overshoot < 0
      ? expectedFrames
      : expectedFrames + step * (overshoot ~/ step + 1);
  final etaSeconds = uniqueFrames >= 3 && elapsedSeconds >= 1 && rate > 0
      ? (target - uniqueFrames) / rate
      : null;
  return TransferProgressEstimate(
    fraction: fraction,
    expectedFrames: expectedFrames,
    etaSeconds: etaSeconds,
    phase: phase,
  );
}

String formatDuration(double seconds) {
  final rounded = math.max(1, seconds.ceil());
  if (rounded < 60) return '${rounded}s';
  final minutes = rounded ~/ 60;
  final remainder = rounded % 60;
  if (minutes < 60) {
    return remainder == 0 ? '${minutes}m' : '${minutes}m ${remainder}s';
  }
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return remainingMinutes == 0
      ? '${hours}h'
      : '${hours}h ${remainingMinutes}m';
}
