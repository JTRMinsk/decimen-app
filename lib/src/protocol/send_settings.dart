// The sender's transmit tuning, in one place.
//
// Ported from shared/send-settings.ts.

/// What the no-signal hint tells the user to turn the sender down to.
const int noSignalHintFrameBytes = 1465;
const int noSignalHintTxFps = 24;

const int defaultTxFps = 60;
const int defaultFrameBytes = 2953;

// The hint values appear in these lists by construction, not by coincidence.
// 55 sits just under the 60 Hz ceiling: on 120 Hz displays it gets a clean
// ≥2 refresh cycles per frame.
const List<int> txFpsOptions = [
  10,
  15,
  20,
  noSignalHintTxFps,
  30,
  55,
  defaultTxFps,
];
const List<int> frameBytesOptions = [
  500,
  1000,
  noSignalHintFrameBytes,
  1850,
  2331,
  defaultFrameBytes,
];
