// How much payload fits in a stream at a given frame size.
//
// Ported from shared/frame-capacity.ts.

import 'protocol.dart';

/// `k` is a u16 in the frame header.
const int maxSourceBlocks = 0xffff;

/// Payload bytes per frame, once the header has taken its cut.
int blockLength(int frameBytes) {
  return frameBytes - headerLen;
}

/// Source blocks a payload splits into at this frame size.
///
/// A frame size at or below the 22-byte header has no room for payload, which
/// JavaScript models as `Math.ceil(x / 0) === Infinity`. Dart's `double.ceil`
/// throws on infinity instead, so return one past the block-number ceiling to
/// keep `fitsInOneStream` false for such a frame size.
int sourceBlockCount(int payloadBytes, int frameBytes) {
  final block = blockLength(frameBytes);
  if (block <= 0) return maxSourceBlocks + 1;
  return (payloadBytes / block).ceil();
}

bool fitsInOneStream(int payloadBytes, int frameBytes) {
  return sourceBlockCount(payloadBytes, frameBytes) <= maxSourceBlocks;
}

/// The smallest bytes-per-frame that can carry this payload at all.
int minimumFrameBytes(int payloadBytes) {
  return (payloadBytes / maxSourceBlocks).ceil() + headerLen;
}

/// The smallest offered setting that works, so the sender can name a value that
/// is actually in the dropdown instead of the bare arithmetic minimum.
int? smallestSufficientFrameSize(int payloadBytes, List<int> options) {
  final minimum = minimumFrameBytes(payloadBytes);
  final sufficient = options.where((value) => value >= minimum).toList()..sort();
  return sufficient.isEmpty ? null : sufficient.first;
}
