// Golden vectors ported verbatim from tests/fountain.test.ts.
//
// fountain.dart IS the wire format. Sender and receiver derive every frame's
// block subset independently and never compare notes, so a change to dlog(),
// solitonCdf(), frameSeed(), splitmix32() or frameIndices() breaks
// compatibility silently. These are golden vectors, not behavioural tests.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:decimen_app/src/protocol/fountain.dart';
import 'package:decimen_app/src/protocol/protocol.dart';

String _hex8(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';

/// Deterministic filler — the fingerprints below are recorded against it.
Uint8List _testPayload(int byteLength) {
  final payload = Uint8List(byteLength);
  for (int i = 0; i < byteLength; i++) {
    payload[i] = (i * 37 + (i >> 8) * 11) & 0xff;
  }
  return payload;
}

void main() {
  group('dlog', () {
    test('is bit-exact against its recorded values', () {
      final golden = <List<double>>[
        [1, 0],
        [1.5, 0.4054651081081644],
        [2, 0.6931471805599453],
        [2.718281828459045, 1],
        [10, 2.3025850929940455],
        [20, 2.995732273553991],
        [200, 5.298317366548036],
        [2000, 7.600902459542082],
        [2986, 8.001689978099137],
        [44000, 10.691944912900398],
        [131070, 11.78348681061359],
      ];
      for (final pair in golden) {
        expect(dlog(pair[0]), pair[1], reason: 'dlog(${pair[0]}) drifted');
      }
    });

    test('is bit-exact across every input the degree distribution can reach',
        () {
      final values = Float64List(65535 + 64 * 4096);
      int n = 0;
      for (int k = 1; k <= 65535; k++) {
        values[n++] = dlog(2.0 * k);
      }
      for (int i = 64; i < 64 * 4096; i++) {
        values[n++] = dlog(i / 64);
      }
      final digest = fnv1a(Uint8List.view(values.buffer, 0, n * 8));
      expect(_hex8(digest), '0x27b0f3cc', reason: 'dlog changed');
    });

    test('is accurate within an ulp of math.log but NOT interchangeable', () {
      const epsilon = 2.220446049250313e-16; // 2^-52
      int differing = 0;
      double worstUlp = 0;
      for (int k = 2; k <= 20000; k++) {
        for (final x in [k.toDouble(), k / 0.5]) {
          final ours = dlog(x);
          final native = math.log(x);
          if (ours != native) differing++;
          worstUlp = math.max(
              worstUlp, (ours - native).abs() / (native.abs() * epsilon));
        }
      }
      expect(worstUlp <= 2, isTrue, reason: 'dlog drifted from math.log');
      expect(differing > 0, isTrue,
          reason: 'dlog now matches math.log bit-for-bit — did it become math.log?');
    });
  });

  group('degree sampling', () {
    test('the soliton CDF is a well-formed distribution', () {
      for (final k in [1, 2, 17, 179, 716, 22000]) {
        final cdf = solitonCdf(k);
        expect(cdf.length, k);
        expect(cdf[k - 1], 1, reason: 'k=$k CDF must terminate at exactly 1');
        for (int i = 1; i < k; i++) {
          expect(cdf[i] >= cdf[i - 1], isTrue,
              reason: 'k=$k CDF is not monotonic at $i');
        }
        expect(cdf[0] > 0, isTrue,
            reason: 'k=$k degree 1 must have non-zero mass or peeling never starts');
      }
    });

    test('the soliton CDF is bit-identical to its recorded fingerprint', () {
      final golden = <int, String>{
        1: '0x8c6a9878',
        2: '0x2417b297',
        17: '0x2ba41e3c',
        179: '0xe8b6340a',
        716: '0x28d31438',
        5000: '0x357a4c9a',
        22000: '0xfc512a92',
      };
      golden.forEach((k, expected) {
        final cdf = solitonCdf(k);
        final digest = fnv1a(Uint8List.view(
            cdf.buffer, cdf.offsetInBytes, cdf.lengthInBytes));
        expect(_hex8(digest), expected,
            reason: 'k=$k degree distribution changed — senders and receivers will desync');
      });
    });

    test('frameIndices matches its recorded subsets', () {
      final golden = <int, List<List<int>>>{
        1: [
          [0],
          [0],
          [0],
          [0],
          [0]
        ],
        2: [
          [1],
          [1],
          [1],
          [0],
          [1]
        ],
        17: [
          [3, 14],
          [12, 0],
          [6, 8],
          [15, 16, 13],
          [11, 2, 16]
        ],
        179: [
          [27, 39],
          [30, 55],
          [155, 125],
          [28, 132, 88],
          [39, 75, 24]
        ],
        716: [
          [27, 397],
          [567, 592],
          [155, 304],
          [386, 311, 625],
          [39, 433, 382]
        ],
      };
      const seqs = [0, 1, 2, 41, 1000];
      golden.forEach((k, expected) {
        final cdf = solitonCdf(k);
        for (int i = 0; i < seqs.length; i++) {
          expect(frameIndices(k, cdf, 4242, seqs[i]), expected[i],
              reason: 'k=$k seq=${seqs[i]} subset changed — this is a breaking wire-format change');
        }
      });
    });

    test('frameIndices always yields distinct in-range blocks', () {
      for (final k in [1, 2, 17, 179, 4096]) {
        final cdf = solitonCdf(k);
        for (int seq = 0; seq < 3000; seq++) {
          final idx = frameIndices(k, cdf, 9, seq);
          expect(idx.isNotEmpty && idx.length <= k, isTrue,
              reason: 'k=$k seq=$seq degree ${idx.length}');
          expect(idx.toSet().length, idx.length,
              reason: 'k=$k seq=$seq repeated a block index');
          for (final b in idx) {
            expect(b >= 0 && b < k, isTrue,
                reason: 'k=$k seq=$seq index $b');
          }
        }
      }
    });

    test('the same seq on a different session picks a different subset', () {
      final cdf = solitonCdf(179);
      final a = frameIndices(179, cdf, 1, 0);
      final b = frameIndices(179, cdf, 2, 0);
      expect(a, isNot(equals(b)));
    });
  });

  group('full encoder stream', () {
    test('the encoded stream is byte-identical to its recorded fingerprint', () {
      final golden = <List<int>>[
        [1, 64, 1, 0xf6a115c5],
        [23, 64, 7, 0x4a5d3eaa],
        [179, 2933, 4242, 0x54f78d05],
        [716, 1445, 65535, 0x75b73b85],
      ];
      for (final row in golden) {
        final k = row[0], blockLen = row[1], sessionId = row[2];
        final encoder = LTEncoder(_testPayload(k * blockLen - 7), blockLen, sessionId);
        final stream = Uint8List(64 * blockLen);
        for (int seq = 0; seq < 64; seq++) {
          stream.setRange(seq * blockLen, (seq + 1) * blockLen, encoder.encode(seq));
        }
        final actual = 'k=${encoder.k} fnv=${_hex8(fnv1a(stream))}';
        expect(actual, 'k=$k fnv=${_hex8(row[3])}',
            reason: 'stream for k=$k/$blockLen/$sessionId changed');
      }
    });

    test('every frame is exactly blockLen bytes', () {
      const blockLen = 1445;
      final encoder = LTEncoder(_testPayload(blockLen * 5 + 1), blockLen, 3);
      expect(encoder.k, 6);
      for (int seq = 0; seq < 200; seq++) {
        expect(encoder.encode(seq).length, blockLen);
      }
    });
  });

  group('round trip', () {
    ({int frames, double overhead, double wallClock, Uint8List? recovered})
        roundTrip(int byteLength, int blockLen, int sessionId,
            [double dropRate = 0]) {
      final payload = _testPayload(byteLength);
      final encoder = LTEncoder(payload, blockLen, sessionId);
      final decoder = LTDecoder(encoder.k, blockLen, sessionId, byteLength);
      final rnd = splitmix32(sessionId);
      int seq = 0;
      final ceiling = encoder.k * 80 + 5000;
      while (!decoder.isComplete && seq < ceiling) {
        if (rnd() / 4294967296.0 >= dropRate) {
          decoder.addFrame(seq, encoder.encode(seq));
        }
        seq++;
      }
      return (
        frames: decoder.framesNew,
        overhead: decoder.framesNew / encoder.k,
        wallClock: seq / encoder.k,
        recovered: decoder.assemble(),
      );
    }

    test('a re-swept block the receiver already solved counts as redundant', () {
      const blockLen = 64;
      final payload = _testPayload(23 * blockLen - 7);
      final encoder = LTEncoder(payload, blockLen, 77);
      final decoder = LTDecoder(encoder.k, blockLen, 77, payload.length);

      decoder.addFrame(0, encoder.encode(0));
      expect(decoder.solvedCount, 1);
      expect(decoder.framesRedundant, 0);

      final nextCycle = cycleLength(encoder.k);
      decoder.addFrame(nextCycle, encoder.encode(nextCycle));
      expect(decoder.framesNew, 2);
      expect(decoder.framesDup, 0);
      expect(decoder.framesRedundant, 1);
      expect(decoder.solvedCount, 1);

      decoder.addFrame(1, encoder.encode(1));
      expect(decoder.framesRedundant, 1);
      expect(decoder.solvedCount, 2);
    });

    test('a payload survives the fountain exactly', () {
      final cases = [
        [7, 2933],
        [2933, 2933],
        [50000, 1445],
        [512 * 1024, 2933],
        [2 * 1024 * 1024, 2933],
      ];
      for (final c in cases) {
        final r = roundTrip(c[0], c[1], 11);
        expect(r.recovered, isNotNull, reason: '${c[0]}B did not complete');
        expect(r.recovered, _testPayload(c[0]));
      }
    });

    test('dropping 30% of frames costs time, never correctness', () {
      final r = roundTrip(512 * 1024, 2933, 23, 0.3);
      expect(r.recovered, isNotNull);
      expect(r.recovered, _testPayload(512 * 1024));
      expect(r.wallClock < 2.8, isTrue,
          reason: 'wall clock ${r.wallClock.toStringAsFixed(2)} seqs/block is too high');
      expect(r.overhead < 1.8, isTrue,
          reason: 'unique-frame overhead ${r.overhead.toStringAsFixed(2)} is too high');
    });

    test('a receiver that catches one clean sweep pays zero fountain overhead',
        () {
      const byteLength = 200000;
      const blockLen = 1445;
      final payload = _testPayload(byteLength);
      final encoder = LTEncoder(payload, blockLen, 55);
      final decoder = LTDecoder(encoder.k, blockLen, 55, byteLength);
      for (int seq = 0; seq < encoder.k; seq++) {
        decoder.addFrame(seq, encoder.encode(seq));
      }
      expect(decoder.isComplete, isTrue);
      expect(decoder.framesNew, encoder.k);
      expect(decoder.assemble(), payload);
    });

    test('the carousel composition is systematic in the sweep, mid-degree after',
        () {
      for (final k in [1, 17, 179, 4096]) {
        expect(cycleLength(k), 2 * k);
        for (final pos in {0, k >> 1, k - 1}) {
          expect(frameComposition(k, 9, pos), [pos],
              reason: 'k=$k sweep pos=$pos');
          expect(frameComposition(k, 9, pos + 6 * cycleLength(k)), [pos]);
        }
        for (final seq in [k, k + 1, 2 * k - 1]) {
          final idx = frameComposition(k, 9, seq);
          expect(idx.length >= math.min(k, 4) && idx.length <= math.min(k, 24),
              isTrue,
              reason: 'k=$k seq=$seq degree ${idx.length}');
          expect(idx.toSet().length, idx.length);
          for (final b in idx) {
            expect(b >= 0 && b < k, isTrue);
          }
        }
      }
    });

    test('a receiver joining mid-cycle completes without a handshake', () {
      const byteLength = 512 * 1024;
      const blockLen = 2933;
      final payload = _testPayload(byteLength);
      final encoder = LTEncoder(payload, blockLen, 91);
      final decoder = LTDecoder(encoder.k, blockLen, 91, byteLength);
      final start = encoder.k ~/ 3;
      int seq = start;
      while (!decoder.isComplete && seq < start + encoder.k * 4) {
        decoder.addFrame(seq, encoder.encode(seq));
        seq++;
      }
      expect(decoder.isComplete, isTrue);
      expect(decoder.assemble(), payload);
      final wallClock = (seq - start) / encoder.k;
      expect(wallClock < 1.7, isTrue,
          reason: 'mid-join took ${wallClock.toStringAsFixed(2)} seqs/block');
    });

    test('frames decode in any order', () {
      const byteLength = 200000;
      const blockLen = 1445;
      final payload = _testPayload(byteLength);
      final encoder = LTEncoder(payload, blockLen, 77);

      final captured = <(int, Uint8List)>[];
      for (int seq = 0; seq < (encoder.k * 2.5).ceil(); seq++) {
        captured.add((seq, encoder.encode(seq)));
      }
      final shuffled = [...captured];
      final rnd = splitmix32(5);
      for (int i = shuffled.length - 1; i > 0; i--) {
        final j = rnd() % (i + 1);
        final tmp = shuffled[i];
        shuffled[i] = shuffled[j];
        shuffled[j] = tmp;
      }

      final decoder = LTDecoder(encoder.k, blockLen, 77, byteLength);
      for (final (seq, block) in shuffled) {
        decoder.addFrame(seq, block);
        if (decoder.isComplete) break;
      }
      expect(decoder.isComplete, isTrue);
      expect(decoder.assemble(), payload);
    });

    test('repeated frames are counted but never corrupt the decode', () {
      const byteLength = 60000;
      const blockLen = 1445;
      final payload = _testPayload(byteLength);
      final encoder = LTEncoder(payload, blockLen, 31);
      final decoder = LTDecoder(encoder.k, blockLen, 31, byteLength);

      int seq = 0;
      while (!decoder.isComplete) {
        final block = encoder.encode(seq);
        decoder.addFrame(seq, block);
        decoder.addFrame(seq, block); // the camera re-reads the same on-screen frame
        seq++;
      }
      expect(decoder.framesDup >= decoder.framesNew - 1, isTrue);
      expect(decoder.assemble(), payload);
    });

    test('a single-block payload completes on its first frame', () {
      final payload = _testPayload(900);
      final encoder = LTEncoder(payload, 2933, 5);
      expect(encoder.k, 1);
      final decoder = LTDecoder(1, 2933, 5, 900);
      decoder.addFrame(0, encoder.encode(0));
      expect(decoder.isComplete, isTrue);
      expect(decoder.assemble(), payload);
    });

    test('an incomplete decoder assembles nothing', () {
      final encoder = LTEncoder(_testPayload(50000), 1445, 13);
      final decoder = LTDecoder(encoder.k, 1445, 13, 50000);
      decoder.addFrame(0, encoder.encode(0));
      expect(decoder.isComplete, isFalse);
      expect(decoder.assemble(), isNull);
    });
  });
}
