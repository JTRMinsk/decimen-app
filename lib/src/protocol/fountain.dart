// Systematic-carousel fountain code (wire format v2, unchanged in v3) —
// ported bit-for-bit from the reference implementation's shared/fountain.ts.
//
// The sender emits an endless carousel: a systematic sweep of all K blocks,
// then K mid-degree repair frames, then the next cycle. The v1 soliton stream
// (dlog, solitonCdf, frameIndices) is kept and golden-tested, but is no
// longer emitted.
//
// Red lines, carried over from the reference:
// - dlog() must NOT be replaced with math.log. Native log is platform-approximated;
//   sender and receiver that disagree by 1 ulp desync silently and never finish.
// - splitmix32 / fnv1a must be integer-exact (32-bit), not swapped for any other
//   PRNG or hash.

import 'dart:math' as math;
import 'dart:typed_data';

import 'protocol.dart';

const double _ln2 = 0.6931471805599453;
const double _invTwoPow32 = 1.0 / 4294967296.0; // 2^-32, exactly representable

/// Deterministic natural log: exact-ops range reduction + atanh series.
///
/// Exported only so tests can pin it. This is wire format, not a utility: it
/// differs from `math.log` by up to 1 ulp on roughly a quarter of the inputs
/// solitonCdf() feeds it, which is enough to shift a CDF entry and flip a
/// sampled degree. Swapping it for `math.log` would desync any sender and
/// receiver that don't share an engine.
double dlog(double x) {
  int e = 0;
  double m = x;
  while (m >= 1.5) {
    m /= 2;
    e++;
  }
  while (m < 0.75) {
    m *= 2;
    e--;
  }
  final z = (m - 1) / (m + 1);
  final z2 = z * z;
  double term = z;
  double sum = 0;
  for (int n = 1; n <= 21; n += 2) {
    sum += term / n;
    term *= z2;
  }
  return e * _ln2 + 2 * sum;
}

const double _solitonC = 0.1;
const double _solitonDelta = 0.5;

/// Robust-soliton degree CDF for k source blocks. Exported for the same
/// wire-format pinning reason as dlog() and frameIndices().
Float64List solitonCdf(int k) {
  final cdf = Float64List(k);
  if (k == 1) {
    cdf[0] = 1;
    return cdf;
  }
  final r = math.max(1.0, _solitonC * dlog(k / _solitonDelta) * math.sqrt(k));
  final spike = math.min(k, (k / r).ceil());
  double total = 0;
  for (int d = 1; d <= k; d++) {
    final rho = d == 1 ? 1 / k : 1 / (d * (d - 1));
    double tau = 0;
    if (d < spike) {
      tau = r / (d * k);
    } else if (d == spike) {
      tau = (r * math.max(0.0, dlog(r / _solitonDelta))) / k;
    }
    total += rho + tau;
    cdf[d - 1] = total;
  }
  for (int i = 0; i < k; i++) {
    cdf[i] = cdf[i] / total;
  }
  cdf[k - 1] = 1;
  return cdf;
}

int _frameSeed(int sessionId, int seq) {
  int h = (((sessionId + 1) * 0x9e3779b1) & 0xffffffff) ^
      ((seq + 0x85ebca6b) & 0xffffffff);
  h = ((h ^ (h >>> 13)) * 0xc2b2ae35) & 0xffffffff;
  return (h ^ (h >>> 16)) & 0xffffffff;
}

/// The block indices XORed into frame `seq` — identical on both ends.
///
/// Exported for the golden-vector tests. Sender and receiver derive this
/// independently and never compare notes, so any change here is a breaking
/// wire-format change.
List<int> frameIndices(int k, Float64List cdf, int sessionId, int seq) {
  final rnd = splitmix32(_frameSeed(sessionId, seq));
  // inverse-CDF sample the degree
  final u = rnd() * _invTwoPow32; // 2 ** -32
  int lo = 0;
  int hi = k - 1;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (cdf[mid] >= u) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  final d = math.min(k, lo + 1);
  if (d > (k >> 3)) {
    // large degree: partial Fisher–Yates over an identity array
    final scratch = Uint32List(k);
    for (int i = 0; i < k; i++) {
      scratch[i] = i;
    }
    final out = List<int>.filled(d, 0);
    for (int i = 0; i < d; i++) {
      final j = i + (rnd() % (k - i));
      final t = scratch[i];
      scratch[i] = scratch[j];
      scratch[j] = t;
      out[i] = scratch[i];
    }
    return out;
  }
  final set = <int>{};
  while (set.length < d) {
    set.add(rnd() % k);
  }
  return set.toList();
}

/// Frames per carousel cycle: one systematic sweep of all k blocks, then k
/// repair frames for whatever the sweep dropped.
int cycleLength(int k) => 2 * k;

const int _repairDegreeMin = 4;
const int _repairDegreeMax = 24;

/// Repair frames are uniform mid-degree (4–24), NOT robust-soliton.
List<int> _repairIndices(int k, int sessionId, int seq) {
  final rnd = splitmix32(_frameSeed(sessionId, seq));
  final d = math.min(
      k, _repairDegreeMin + (rnd() % (_repairDegreeMax - _repairDegreeMin + 1)));
  final set = <int>{};
  while (set.length < d) {
    set.add(rnd() % k);
  }
  return set.toList();
}

/// Block subset for frame `seq`: systematic during the sweep, mid-degree
/// repair after. This carousel arrived with wire v2 and is unchanged in v3.
List<int> frameComposition(int k, int sessionId, int seq) {
  final pos = seq % cycleLength(k);
  return pos < k ? [pos] : _repairIndices(k, sessionId, seq);
}

void _xorInto(Uint32List dst, Uint32List src) {
  for (int i = 0; i < dst.length; i++) {
    dst[i] = dst[i] ^ src[i];
  }
}

class LTEncoder {
  final int blockLen;
  final int sessionId;
  late final int k;
  late final int _words;
  late final Uint32List _blocks;

  LTEncoder(Uint8List payload, this.blockLen, this.sessionId) {
    k = math.max(1, (payload.length / blockLen).ceil());
    _words = (blockLen / 4).ceil();
    _blocks = Uint32List(k * _words);
    final bytes = Uint8List.view(_blocks.buffer);
    for (int b = 0; b < k; b++) {
      final start = b * blockLen;
      final end = math.min((b + 1) * blockLen, payload.length);
      bytes.setRange(b * _words * 4, b * _words * 4 + (end - start), payload, start);
    }
  }

  Uint8List encode(int seq) {
    final idx = frameComposition(k, sessionId, seq);
    final out = Uint32List(_words);
    for (final b in idx) {
      final off = b * _words;
      for (int w = 0; w < _words; w++) {
        out[w] = out[w] ^ _blocks[off + w];
      }
    }
    return Uint8List.view(out.buffer, 0, blockLen);
  }
}

class _PendingFrame {
  final Set<int> idx;
  final Uint32List words;
  _PendingFrame(this.idx, this.words);
}

class LTDecoder {
  final int k;
  final int blockLen;
  final int sessionId;
  final int totalLen;
  late final int _words;
  late final List<Uint32List?> _solved;
  final Map<int, Set<_PendingFrame>> _byBlock = {};
  final Set<int> _seen = {};
  int solvedCount = 0;
  int framesNew = 0;
  int framesDup = 0;

  /// Frames with a NEW seq that carried no new information — every block
  /// they cover was already solved.
  int framesRedundant = 0;

  LTDecoder(this.k, this.blockLen, this.sessionId, this.totalLen) {
    _words = (blockLen / 4).ceil();
    _solved = List<Uint32List?>.filled(k, null);
  }

  bool get isComplete => solvedCount >= k;

  void addFrame(int seq, Uint8List block) {
    if (_seen.contains(seq)) {
      framesDup++;
      return;
    }
    _seen.add(seq);
    framesNew++;
    if (isComplete) return;

    final idx = frameComposition(k, sessionId, seq).toSet();
    final words = Uint32List(_words);
    Uint8List.view(words.buffer)
        .setRange(0, math.min(blockLen, block.length), block);
    for (final b in idx.toList()) {
      final s = _solved[b];
      if (s != null) {
        _xorInto(words, s);
        idx.remove(b);
      }
    }
    if (idx.isEmpty) {
      framesRedundant++;
      return;
    }
    if (idx.length == 1) {
      _resolve(idx.first, words);
      return;
    }
    final pf = _PendingFrame(idx, words);
    for (final b in idx) {
      _byBlock.putIfAbsent(b, () => <_PendingFrame>{}).add(pf);
    }
  }

  /// Peeling cascade: solve a block, reduce every frame waiting on it, repeat.
  void _resolve(int b0, Uint32List w0) {
    final queue = <(int, Uint32List)>[(b0, w0)];
    while (queue.isNotEmpty) {
      final (b, w) = queue.removeLast();
      if (_solved[b] != null) continue;
      _solved[b] = w;
      solvedCount++;
      final waiting = _byBlock[b];
      if (waiting == null) continue;
      _byBlock.remove(b);
      for (final pf in waiting) {
        _xorInto(pf.words, w);
        pf.idx.remove(b);
        if (pf.idx.length == 1) {
          final r = pf.idx.first;
          _byBlock[r]?.remove(pf);
          if (_solved[r] == null) queue.add((r, pf.words));
        }
      }
    }
  }

  Uint8List? assemble() {
    if (!isComplete) return null;
    final out = Uint8List(totalLen);
    for (int b = 0; b < k; b++) {
      final start = b * blockLen;
      final len = math.min(blockLen, totalLen - start);
      if (len > 0) {
        out.setRange(start, start + len, Uint8List.view(_solved[b]!.buffer, 0, len));
      }
    }
    return out;
  }
}
