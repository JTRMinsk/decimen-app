// Ported verbatim from tests/frame-capacity.test.ts.

import 'package:flutter_test/flutter_test.dart';

import 'package:decimen_app/src/protocol/frame_capacity.dart';
import 'package:decimen_app/src/protocol/protocol.dart';
import 'package:decimen_app/src/protocol/send_settings.dart';

void main() {
  final offered = frameBytesOptions;

  test('the header takes its cut off every frame', () {
    expect(blockLength(2953), 2953 - headerLen);
    expect(blockLength(500), 500 - headerLen);
  });

  test('block count rounds up, because a partial block still needs a frame', () {
    final perFrame = blockLength(2953);
    expect(sourceBlockCount(1, 2953), 1);
    expect(sourceBlockCount(perFrame, 2953), 1);
    expect(sourceBlockCount(perFrame + 1, 2953), 2);
    expect(sourceBlockCount(10 * perFrame, 2953), 10);
  });

  test('the block ceiling bites well below the file size limit', () {
    expect(fitsInOneStream(30 * 1024 * 1024, 500), isFalse);
    expect(fitsInOneStream(20 * 1024 * 1024, 500), isTrue);
    expect(fitsInOneStream(maxFileBytes, 2953), isTrue);
  });

  test('minimumFrameBytes is the smallest frame size that actually fits', () {
    for (final payload in [1, 1000, 30 * 1024 * 1024, 64 * 1024 * 1024, maxFileBytes]) {
      final minimum = minimumFrameBytes(payload);
      expect(fitsInOneStream(payload, minimum), isTrue,
          reason: '$payload does not fit at $minimum');
      if (sourceBlockCount(payload, minimum) > 1) {
        expect(fitsInOneStream(payload, minimum - 1), isFalse,
            reason: '$payload unexpectedly still fits at ${minimum - 1}');
      }
    }
  });

  test('the suggested dropdown option always works', () {
    for (final payload in [30 * 1024 * 1024, 40 * 1024 * 1024, maxFileBytes]) {
      for (final frameBytes in offered) {
        if (fitsInOneStream(payload, frameBytes)) continue;
        final suggestion = smallestSufficientFrameSize(payload, offered);
        expect(suggestion, isNotNull, reason: 'no suggestion for $payload at $frameBytes');
        expect(offered.contains(suggestion), isTrue,
            reason: '$suggestion is not an offered option');
        expect(fitsInOneStream(payload, suggestion!), isTrue,
            reason: '$suggestion still does not fit');
        expect(suggestion > frameBytes, isTrue,
            reason: 'suggesting the setting that just failed helps nobody');
      }
    }
  });

  test('an offered option always exists for any legal payload', () {
    final worstCase = maxFileBytes + 49 + 2 * 0xffff;
    final suggestion = smallestSufficientFrameSize(worstCase, offered);
    expect(suggestion, isNotNull,
        reason: 'the dropdown cannot express the largest legal payload');
    expect(fitsInOneStream(worstCase, suggestion!), isTrue);
  });

  test('no suggestion when nothing on offer is big enough', () {
    expect(smallestSufficientFrameSize(maxSourceBlocks * 4000, offered), isNull);
  });
}
