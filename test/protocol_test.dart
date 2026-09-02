// Ported verbatim from tests/protocol.test.ts.
//
// packFile/unpackFile/verifyFile are synchronous in Dart (package:crypto and
// dart:io zlib are synchronous), but the byte layout and gzip decisions are
// identical to the reference.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:decimen_app/src/protocol/protocol.dart';

Matcher _formatException(String fragment) => throwsA(
    isA<FormatException>().having((e) => e.message, 'message', contains(fragment)));

void main() {
  group('container', () {
    test('arbitrary file metadata and bytes survive the optical container', () {
      final source = Uint8List.fromList([0, 1, 2, 127, 128, 254, 255]);
      final packed = packFile('résumé.bin', 'application/octet-stream', source);
      final recovered = unpackFile(packed.container);

      expect(packed.compression, 'none');
      expect(recovered.name, 'résumé.bin');
      expect(recovered.type, 'application/octet-stream');
      expect(recovered.bytes, source);
      expect(verifyFile(recovered), isTrue);
    });

    test('SHA-256 verification rejects changed file bytes', () {
      final packed = packFile(
          'message.txt', 'text/plain', Uint8List.fromList(utf8.encode('hello')));
      final recovered = unpackFile(packed.container);
      recovered.bytes[0] ^= 0xff;

      expect(verifyFile(recovered), isFalse);
    });

    test('compressible files use gzip and recover exactly', () {
      final source = Uint8List.fromList(
          utf8.encode(List.filled(4000, 'decimen optical transfer\n').join()));
      final packed = packFile('notes.txt', 'text/plain', source);
      final recovered = unpackFile(packed.container);

      expect(packed.compression, 'gzip');
      expect(packed.transmittedSize < source.length / 10, isTrue);
      expect(recovered.compression, 'gzip');
      expect(recovered.bytes, source);
      expect(verifyFile(recovered), isTrue);
    });

    test('gzip output length is bounded by the declared original size', () {
      final source = Uint8List.fromList(
          utf8.encode(List.filled(1000, 'bounded output\n').join()));
      final packed = packFile('bounded.txt', 'text/plain', source);
      final malformed = Uint8List.fromList(packed.container);
      ByteData.sublistView(malformed)
          .setUint32(9, source.length + 1, Endian.little);

      expect(() => unpackFile(malformed), _formatException('gzip payload length'));
    });

    test('malformed optical containers are rejected', () {
      expect(() => unpackFile(Uint8List(49)), _formatException('header is invalid'));
    });

    test('the receiver sanitises the filename rather than trusting the sender', () {
      final cases = <List<String>>[
        ['../../etc/passwd', 'passwd'],
        [r'C:\Windows\System32\drivers\etc\hosts', 'hosts'],
        ['évidence.pdf', 'évidence.pdf'],
        ['report v2 (final).tar.gz', 'report v2 (final).tar.gz'],
      ];
      for (final c in cases) {
        final packed =
            packFile(c[0], 'application/octet-stream', Uint8List.fromList([1, 2, 3]));
        expect(unpackFile(packed.container).name, c[1], reason: 'for ${c[0]}');
      }
    });

    test('filenames that sanitise away fall back to a safe default', () {
      for (final sent in ['..', '.', '/', '   ', '\u0000\u0007']) {
        final packed =
            packFile(sent, 'application/octet-stream', Uint8List.fromList([1]));
        expect(unpackFile(packed.container).name, 'transfer.bin');
      }
    });
  });

  group('frame header', () {
    test('the frame header is byte-for-byte what the wire expects', () {
      final frame = packFrame(
        FrameHeader(
          sessionId: 0xbeef,
          seq: 0x01020304,
          k: 0x0111,
          blockLen: 6,
          totalLen: 0x00fedcba,
          payloadFnv: 0x89abcdef,
          flags: 0,
        ),
        Uint8List.fromList([1, 2, 3, 4, 5, 6]),
      );
      expect(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '),
        'd1 c3 03 00 ef be 04 03 02 01 11 01 06 00 ba dc fe 00 ef cd ab 89 01 02 03 04 05 06',
      );
      expect(frame.length, headerLen + 6);

      final parsed = parseFrame(frame);
      expect(parsed, isNotNull);
      expect(parsed!.header.sessionId, 0xbeef);
      expect(parsed.header.seq, 0x01020304);
      expect(parsed.header.k, 0x0111);
      expect(parsed.header.blockLen, 6);
      expect(parsed.header.totalLen, 0x00fedcba);
      expect(parsed.header.payloadFnv, 0x89abcdef);
      expect(parsed.header.flags, 0);
      expect(parsed.block, Uint8List.fromList([1, 2, 3, 4, 5, 6]));
    });
  });

  group('compression decisions', () {
    test('gzip is skipped for formats it cannot help', () {
      const types = [
        'image/jpeg',
        'image/png',
        'image/webp',
        'image/avif',
        'image/heic',
        'video/mp4',
        'video/quicktime',
        'audio/mpeg',
        'audio/mp4',
        'audio/flac',
        'application/zip',
        'application/gzip',
        'application/x-7z-compressed',
        'application/vnd.rar',
        'application/epub+zip',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.oasis.opendocument.spreadsheet',
        'IMAGE/JPEG',
        'image/jpeg; charset=binary',
      ];
      for (final type in types) {
        expect(isPrecompressedType(type), isTrue, reason: '$type should skip gzip');
      }
    });

    test('gzip is still attempted for anything that might compress', () {
      const types = [
        'text/plain',
        'text/csv',
        'application/json',
        'application/pdf',
        'application/wasm',
        'application/octet-stream',
        'application/vnd.decimen.snippet',
        'image/svg+xml',
        'image/bmp',
        'image/tiff',
        'image/x-icon',
        'audio/wav',
        'audio/x-aiff',
        '',
      ];
      for (final type in types) {
        expect(isPrecompressedType(type), isFalse,
            reason: '$type should still try gzip');
      }
    });

    test('a precompressed file is transmitted verbatim and still round-trips', () {
      final source = Uint8List(4096);
      for (int i = 0; i < source.length; i++) {
        source[i] = ((i * 2654435761) & 0xffffffff) >>> 24;
      }
      final packed = packFile('photo.jpg', 'image/jpeg', source);

      expect(packed.compression, 'none');
      expect(packed.transmittedSize, source.length);
      final recovered = unpackFile(packed.container);
      expect(recovered.bytes, source);
      expect(verifyFile(recovered), isTrue);
    });

    test('declaring a compressible type still gets gzip', () {
      final source = Uint8List.fromList(
          utf8.encode(List.filled(2000, 'the same line over and over\n').join()));
      expect(packFile('log.txt', 'text/plain', source).compression, 'gzip');
      expect(packFile('log.txt', 'image/jpeg', source).compression, 'none');
    });
  });

  group('stream identity', () {
    FrameHeader base() => FrameHeader(
          sessionId: 7,
          seq: 0,
          k: 100,
          blockLen: 2933,
          totalLen: 293300,
          payloadFnv: 0xdeadbeef,
          flags: 0,
        );

    test('changes with every field that must not drift mid-stream', () {
      final identity = streamIdentity(base());

      // seq is the one field that varies within a stream.
      expect(
          streamIdentity(FrameHeader(
              sessionId: 7,
              seq: 9999,
              k: 100,
              blockLen: 2933,
              totalLen: 293300,
              payloadFnv: 0xdeadbeef,
              flags: 0)),
          identity);

      expect(
          streamIdentity(FrameHeader(
              sessionId: 8,
              seq: 0,
              k: 100,
              blockLen: 2933,
              totalLen: 293300,
              payloadFnv: 0xdeadbeef,
              flags: 0)),
          isNot(equals(identity)),
          reason: 'sessionId must force the receiver to start a new decoder');
      expect(
          streamIdentity(FrameHeader(
              sessionId: 7,
              seq: 0,
              k: 101,
              blockLen: 2933,
              totalLen: 293300,
              payloadFnv: 0xdeadbeef,
              flags: 0)),
          isNot(equals(identity)),
          reason: 'k must force the receiver to start a new decoder');
      expect(
          streamIdentity(FrameHeader(
              sessionId: 7,
              seq: 0,
              k: 100,
              blockLen: 2934,
              totalLen: 293300,
              payloadFnv: 0xdeadbeef,
              flags: 0)),
          isNot(equals(identity)),
          reason: 'blockLen must force the receiver to start a new decoder');
      expect(
          streamIdentity(FrameHeader(
              sessionId: 7,
              seq: 0,
              k: 100,
              blockLen: 2933,
              totalLen: 293301,
              payloadFnv: 0xdeadbeef,
              flags: 0)),
          isNot(equals(identity)),
          reason: 'totalLen must force the receiver to start a new decoder');
      expect(
          streamIdentity(FrameHeader(
              sessionId: 7,
              seq: 0,
              k: 100,
              blockLen: 2933,
              totalLen: 293300,
              payloadFnv: 0xdeadbef0,
              flags: 0)),
          isNot(equals(identity)),
          reason: 'payloadFnv must force the receiver to start a new decoder');

      for (int bit = 1; bit <= 0xff; bit <<= 1) {
        if ((bit & criticalFlags) == 0) continue;
        expect(
            streamIdentity(FrameHeader(
                sessionId: 7,
                seq: 0,
                k: 100,
                blockLen: 2933,
                totalLen: 293300,
                payloadFnv: 0xdeadbeef,
                flags: bit)),
            isNot(equals(identity)),
            reason: 'critical flag 0x${bit.toRadixString(16)} must force a new decoder');
      }
    });

    test('ignores the flag bits that are safe to ignore', () {
      final identity = streamIdentity(base());
      for (int bit = 1; bit <= 0xff; bit <<= 1) {
        if (bit & criticalFlags != 0) continue;
        expect(
            streamIdentity(FrameHeader(
                sessionId: 7,
                seq: 0,
                k: 100,
                blockLen: 2933,
                totalLen: 293300,
                payloadFnv: 0xdeadbeef,
                flags: bit)),
            identity,
            reason: 'ignorable flag 0x${bit.toRadixString(16)} must not restart the transfer');
      }
    });

    test('fields cannot be confused by the separator', () {
      final a = FrameHeader(
          sessionId: 1,
          seq: 0,
          k: 1,
          blockLen: 23,
          totalLen: 4,
          payloadFnv: 5,
          flags: 0);
      final b = FrameHeader(
          sessionId: 1,
          seq: 0,
          k: 12,
          blockLen: 3,
          totalLen: 4,
          payloadFnv: 5,
          flags: 0);
      expect(streamIdentity(a), isNot(equals(streamIdentity(b))));
    });
  });

  group('parse rejection', () {
    test('frames that are not ours, or not self-consistent, are rejected', () {
      final good = packFrame(
        FrameHeader(
            sessionId: 1,
            seq: 2,
            k: 3,
            blockLen: 4,
            totalLen: 10,
            payloadFnv: 0,
            flags: 0),
        Uint8List.fromList([9, 9, 9, 9]),
      );
      expect(parseFrame(good), isNotNull);

      final wrongMagic = Uint8List.fromList(good);
      wrongMagic[0] = 0xd2;
      expect(parseFrame(wrongMagic), isNull, reason: 'a QR code from somewhere else');

      expect(parseFrame(Uint8List.sublistView(good, 0, headerLen)), isNull,
          reason: 'header with no block');
      expect(parseFrame(Uint8List.sublistView(good, 0, good.length - 1)), isNull,
          reason: 'truncated block');

      final zeroK = Uint8List.fromList(good);
      ByteData.sublistView(zeroK).setUint16(10, 0, Endian.little);
      expect(parseFrame(zeroK), isNull, reason: 'k=0 would divide by zero downstream');
    });
  });

  group('cross-version rejection', () {
    Uint8List goodFrame() => packFrame(
          FrameHeader(
              sessionId: 1,
              seq: 2,
              k: 3,
              blockLen: 4,
              totalLen: 10,
              payloadFnv: 0,
              flags: 0),
          Uint8List.fromList([9, 9, 9, 9]),
        );

    Uint8List withByte(int offset, int value) {
      final frame = goodFrame();
      frame[offset] = value;
      return frame;
    }

    test('the magic pair cannot be confused with a pre-versioning format', () {
      expect(goodFrame()[1], isNot(equals(0x0c)));
      expect(goodFrame()[1], isNot(equals(0x0d)));
      expect(goodFrame()[2], wireVersion);
    });

    test('a v3 receiver names a pre-versioning sender instead of going quiet',
        () {
      for (final pair in [
        [0x0c, 1],
        [0x0d, 2],
      ]) {
        final verdict = classifyFrame(withByte(1, pair[0]));
        expect(verdict, FrameVerdictOlderSender(pair[1]));
        expect(frameVerdictMessage(verdict), contains('older Decimen format'));
      }
    });

    test('a v3 receiver names a newer sender instead of going quiet', () {
      final verdict = classifyFrame(withByte(2, wireVersion + 1));
      expect(verdict, FrameVerdictNewerSender(wireVersion + 1));
      expect(frameVerdictMessage(verdict), contains('newer Decimen format'));
      expect(parseFrame(withByte(2, wireVersion + 1)), isNull);
    });

    test('a v3 receiver names an older versioned sender too', () {
      final verdict = classifyFrame(withByte(2, wireVersion - 1));
      expect(verdict, FrameVerdictOlderSender(wireVersion - 1));
      expect(frameVerdictMessage(verdict), contains('Update the sending device'));
    });

    test('version 0 is ours but nonsense, and says nothing', () {
      expect(classifyFrame(withByte(2, 0)), isA<FrameVerdictMalformed>());
      expect(parseFrame(withByte(2, 0)), isNull);
    });

    test('an unknown critical flag is refused with a message', () {
      expect(flagEncrypted & criticalFlags, isNot(equals(0)));
      final verdict = classifyFrame(withByte(3, flagEncrypted));
      expect(verdict, FrameVerdictUnsupportedFlags(flagEncrypted));
      expect(frameVerdictMessage(verdict), contains('cannot read'));
      expect(parseFrame(withByte(3, flagEncrypted)), isNull);
    });

    test('an unknown ignorable flag decodes anyway', () {
      for (int bit = 1; bit <= 0xff; bit <<= 1) {
        if (bit & criticalFlags != 0) continue;
        final frame = withByte(3, bit);
        expect(classifyFrame(frame), isA<FrameVerdictOk>(),
            reason: 'flag 0x${bit.toRadixString(16)}');
        expect(parseFrame(frame)!.header.flags, bit);
      }
    });

    test('a mixed flags byte is judged on its critical half alone', () {
      int ignorable = 1;
      while (ignorable & criticalFlags != 0) {
        ignorable <<= 1;
      }
      expect(classifyFrame(withByte(3, ignorable | flagEncrypted)),
          FrameVerdictUnsupportedFlags(flagEncrypted));
    });

    test('frames that are not Decimen stay silent', () {
      for (final frame in [withByte(0, 0xd2), Uint8List.fromList([0xd1, 0xc3])]) {
        final verdict = classifyFrame(frame);
        expect(verdict, isA<FrameVerdictForeign>());
        expect(frameVerdictMessage(verdict), isNull);
      }
    });

    test('a stray 0xD1 alone never produces version advice', () {
      final legacy = {0x0c, 0x0d};
      final magic1 = goodFrame()[1];
      for (int byte1 = 0; byte1 <= 0xff; byte1++) {
        if (byte1 == magic1 || legacy.contains(byte1)) continue;
        final verdict = classifyFrame(withByte(1, byte1));
        expect(verdict, isA<FrameVerdictForeign>(),
            reason: 'byte1 0x${byte1.toRadixString(16)} is not ours');
        expect(frameVerdictMessage(verdict), isNull);
      }
    });

    test('a good v3 frame classifies clean and carries no flags', () {
      expect(classifyFrame(goodFrame()), isA<FrameVerdictOk>());
      expect(frameVerdictMessage(const FrameVerdictOk()), isNull);
      expect(parseFrame(goodFrame())!.header.flags, 0);
    });
  });
}
