// Ported verbatim from tests/progress.test.ts.

import 'package:flutter_test/flutter_test.dart';

import 'package:decimen_app/src/protocol/progress.dart';

// k=100 is a ~300 KB file at 2953 bytes/frame.
// v2 overhead(100) = 1.02, so 102 expected frames and 2 of expected redundancy.
const int k = 100;
const int expectedFrames = 102;

void main() {
  test('the carousel needs almost no fountain overhead, and the model says so',
      () {
    for (final kk in [2, 5, 25, 100, 500, 5000, 65535]) {
      final value = expectedFountainOverhead(kk);
      expect(value >= 1 && value <= 1.05, isTrue, reason: 'k=$kk: $value');
    }
    expect(expectedFountainOverhead(1), 1,
        reason: 'a single block needs exactly one frame');
    expect(expectedFountainOverhead(0), 1,
        reason: 'guards against a zero-block stream');
  });

  test('progress and ETA follow the observed unique-frame rate', () {
    final progress = estimateTransferProgress(k, 50, 10);
    expect(progress.expectedFrames, expectedFrames);
    expect(progress.fraction, 0.43);
    expect(progress.phase, 'collecting');
    expect(progress.etaSeconds, 10.4);
  });

  test('progress keeps moving through redundant frames', () {
    double at(int frames) => estimateTransferProgress(k, frames, 20).fraction;

    expect(estimateTransferProgress(k, 2, 4).etaSeconds, isNull,
        reason: 'too early to guess');
    expect(at(k), 0.86, reason: 'the theoretical minimum is 86% of the bar');
    expect(at(k + 1), 0.91, reason: 'half the expected redundancy is 91%');
    expect((at(expectedFrames) - 0.96).abs() < 1e-9, isTrue,
        reason: 'expected frames lands on 96%');
    expect(at(expectedFrames + 18) > 0.96, isTrue,
        reason: 'running long still creeps forward');
    expect(at(expectedFrames + 30) < 0.99, isTrue,
        reason: 'and never reaches 100% on frame count alone');
    expect(at(expectedFrames * 4) <= 0.99, isTrue);
  });

  test('the ETA keeps quoting a time once a stream runs long', () {
    final overrun = estimateTransferProgress(k, expectedFrames + 5, 30);
    expect(overrun.etaSeconds != null && overrun.etaSeconds! > 0, isTrue);
    expect(overrun.phase, 'decoding');
  });

  test('decoded blocks can advance progress and completion caps at 99%', () {
    expect(estimateTransferProgress(k, 101, 20, 95).fraction, 0.9405);
    expect(estimateTransferProgress(k, 101, 20, 100).fraction, 0.99);
  });

  test('the bar cannot run far ahead of solved blocks', () {
    final capped = estimateTransferProgress(k, 98, 20, 30);
    expect((capped.fraction - 0.86 * 0.42).abs() < 1e-9, isTrue,
        reason: 'got ${capped.fraction}');
    expect(estimateTransferProgress(k, 101, 20, 95).fraction, 0.9405);
    expect(estimateTransferProgress(k, 50, 10).fraction, 0.43);
  });

  test('durations stay compact and readable', () {
    expect(formatDuration(12.1), '13s');
    expect(formatDuration(75.1), '1m 16s');
    expect(formatDuration(3661), '1h 1m');
  });
}
