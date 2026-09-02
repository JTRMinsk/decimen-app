// Frame protocol: every QR frame is fully self-describing, so there is NO
// handshake — the receiver locks onto a stream mid-flight, and a new session
// id on any frame simply starts a fresh transfer.
//
// Layout (little-endian), 22 bytes, followed by `blockLen` payload bytes:
//   0  u8   magic 0xD1   ┐ together: "this is a Decimen frame at all"
//   1  u8   magic 0xC3   ┘ magic1 is fixed forever; 0x0C/0x0D mark v1/v2
//   2  u8   version      wire format version — 3
//   3  u8   flags        0x0F must-understand · 0xF0 safe to ignore
//   4  u16  sessionId    random per sender start
//   6  u32  seq          drives the fountain PRNG (see fountain.dart)
//  10  u16  k            source block count
//  12  u16  blockLen     payload bytes per frame
//  14  u32  totalLen     protected file-container length in bytes
//  18  u32  payloadFnv   FNV-1a of the whole container — verified on completion
//
// Ported bit-for-bit from shared/protocol.ts (wire v3). The gzip path uses
// dart:io's top-level gzip codec (RFC-1952, inter-operable with the web's
// CompressionStream).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int headerLen = 22;
const int maxFileBytes = 64 * 1024 * 1024;
const String maxFileLabel = '64 MB';
const int _fileHeaderLen = 49;
const int _magic0 = 0xd1;
const int _magic1 = 0xc3;
const int wireVersion = 3;
const int criticalFlags = 0x0f;
const int flagEncrypted = 0x01;
const int _supportedFlags = 0x00;

/// Byte-1 values of the pre-versioning formats, reserved forever so a receiver
/// can tell "older sender" from "not a Decimen frame at all".
const Map<int, int> _legacyMagic1 = {0x0c: 1, 0x0d: 2};
final Uint8List _fileMagic = Uint8List.fromList([0x44, 0x43, 0x46, 0x32]); // DCF2

typedef CompressionMode = String;

const String compressionNone = 'none';
const String compressionGzip = 'gzip';

class PackedOpticalFile {
  final Uint8List container;
  final CompressionMode compression;
  final int originalSize;
  final int transmittedSize;
  PackedOpticalFile({
    required this.container,
    required this.compression,
    required this.originalSize,
    required this.transmittedSize,
  });
}

class OpticalFile {
  final String name;
  final String type;
  final Uint8List bytes;
  final Uint8List sha256;
  final CompressionMode compression;
  final int transmittedSize;
  OpticalFile({
    required this.name,
    required this.type,
    required this.bytes,
    required this.sha256,
    required this.compression,
    required this.transmittedSize,
  });
}

Uint8List _digest(Uint8List bytes) {
  return Uint8List.fromList(sha256.convert(bytes).bytes);
}

Uint8List _gzip(Uint8List bytes) {
  // The top-level `gzip` codec produces RFC-1952 gzip (with the ISIZE trailer
  // the web's CompressionStream also writes). Constructing `ZLibCodec(gzip: true)`
  // directly has produced zlib-format output on this SDK, so use the codec.
  return Uint8List.fromList(gzip.encode(bytes));
}

/// Inflate with a hard output ceiling.
///
/// The gzip trailer's declared size is attacker-controlled — it arrives over the
/// optical channel like everything else — so it is a hint, never a bound. This
/// counts bytes as they come off the stream and aborts the moment they exceed
/// `maxBytes`.
Uint8List _gunzip(Uint8List bytes, int maxBytes) {
  final chunks = <Uint8List>[];
  int total = 0;
  final sink = _ChunkSink((chunk) {
    total += chunk.length;
    if (total > maxBytes) {
      throw const _GzipExpansionExceeded();
    }
    chunks.add(Uint8List.fromList(chunk));
  });
  try {
    gzip.decoder.startChunkedConversion(sink)
      ..add(bytes)
      ..close();
  } on _GzipExpansionExceeded {
    throw const FormatException(
        'The recovered file expands past its declared length.');
  }
  final out = Uint8List(total);
  int offset = 0;
  for (final c in chunks) {
    out.setRange(offset, offset + c.length, c);
    offset += c.length;
  }
  return out;
}

class _ChunkSink implements Sink<List<int>> {
  final void Function(List<int> chunk) _onChunk;
  _ChunkSink(this._onChunk);
  @override
  void add(List<int> data) => _onChunk(data);
  @override
  void close() {}
}

class _GzipExpansionExceeded implements Exception {
  const _GzipExpansionExceeded();
}

/// Reduce a name to a bare basename.
///
/// Applied on BOTH ends. The sender doing it is a convenience; the receiver
/// doing it is the part that matters, because the name it unpacks arrived over
/// the optical channel and is whatever the other screen chose to display.
String safeFileName(String name) {
  final parts = name.split(RegExp(r'[\\/]'));
  final base = parts.isNotEmpty ? parts.last : '';
  // Strip control characters (NUL and newlines in particular) and the
  // relative-path names that survive a basename split.
  final cleaned = base.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'transfer.bin';
  return cleaned;
}

/// Media types whose bytes are already entropy-coded, keyed by exact subtype.
const Set<String> _precompressedTypes = {
  'application/gzip',
  'application/java-archive',
  'application/vnd.rar',
  'application/x-7z-compressed',
  'application/x-brotli',
  'application/x-bzip',
  'application/x-bzip2',
  'application/x-gzip',
  'application/x-lzma',
  'application/x-rar-compressed',
  'application/x-xz',
  'application/x-zip-compressed',
  'application/zip',
  'application/zstd',
};

final RegExp _compressibleImages = RegExp(
    r'^image/(bmp|x-ms-bmp|svg\+xml|tiff|x-icon|vnd\.microsoft\.icon)$');
final RegExp _compressibleAudio = RegExp(
    r'^audio/(wav|x-wav|wave|vnd\.wave|aiff|x-aiff|basic|l16)$');

/// Would gzip be a waste of time on this?
bool isPrecompressedType(String type) {
  final media = type.split(';').first.trim().toLowerCase();
  if (media.startsWith('video/')) return true;
  if (media.startsWith('image/')) return !_compressibleImages.hasMatch(media);
  if (media.startsWith('audio/')) return !_compressibleAudio.hasMatch(media);
  if (media.startsWith('application/vnd.openxmlformats-officedocument.')) {
    return true;
  }
  if (media.startsWith('application/vnd.oasis.opendocument.')) return true;
  if (media.endsWith('+zip')) return true;
  return _precompressedTypes.contains(media);
}

PackedOpticalFile packFile(String name, String type, Uint8List bytes) {
  if (bytes.isEmpty) throw const FormatException('Choose a non-empty file.');
  if (bytes.length > maxFileBytes) {
    throw FormatException('Files are limited to $maxFileLabel in this build.');
  }

  final nameBytes = utf8.encode(safeFileName(name));
  final typeBytes = utf8.encode(type.isEmpty ? 'application/octet-stream' : type);
  if (nameBytes.length > 0xffff || typeBytes.length > 0xffff) {
    throw const FormatException('The file name or media type is too long.');
  }

  final tryGzip = bytes.length >= 768 && !isPrecompressedType(type);
  final sha256Bytes = _digest(bytes);
  final compressed = tryGzip ? _gzip(bytes) : null;
  Uint8List transmitted;
  String compression;
  if (compressed != null && compressed.length + 64 < bytes.length) {
    transmitted = compressed;
    compression = compressionGzip;
  } else {
    transmitted = bytes;
    compression = compressionNone;
  }
  final out = Uint8List(
      _fileHeaderLen + nameBytes.length + typeBytes.length + transmitted.length);
  final view = ByteData.view(out.buffer);
  out.setRange(0, _fileMagic.length, _fileMagic);
  view.setUint8(4, compression == compressionGzip ? 1 : 0);
  view.setUint16(5, nameBytes.length, Endian.little);
  view.setUint16(7, typeBytes.length, Endian.little);
  view.setUint32(9, bytes.length, Endian.little);
  view.setUint32(13, transmitted.length, Endian.little);
  out.setRange(17, 17 + 32, sha256Bytes);
  out.setRange(_fileHeaderLen, _fileHeaderLen + nameBytes.length, nameBytes);
  out.setRange(_fileHeaderLen + nameBytes.length,
      _fileHeaderLen + nameBytes.length + typeBytes.length, typeBytes);
  out.setRange(_fileHeaderLen + nameBytes.length + typeBytes.length, out.length,
      transmitted);
  return PackedOpticalFile(
    container: out,
    compression: compression,
    originalSize: bytes.length,
    transmittedSize: transmitted.length,
  );
}

OpticalFile unpackFile(Uint8List container) {
  if (container.length < _fileHeaderLen) {
    throw const FormatException('The recovered file header is incomplete.');
  }
  for (int i = 0; i < _fileMagic.length; i++) {
    if (container[i] != _fileMagic[i]) {
      throw const FormatException('The recovered file header is invalid.');
    }
  }

  final view = ByteData.sublistView(container);
  final compressionByte = view.getUint8(4);
  if (compressionByte > 1) {
    throw const FormatException(
        'The recovered file uses unsupported compression.');
  }
  final compression =
      compressionByte == 1 ? compressionGzip : compressionNone;
  final nameLength = view.getUint16(5, Endian.little);
  final typeLength = view.getUint16(7, Endian.little);
  final fileLength = view.getUint32(9, Endian.little);
  final transmittedLength = view.getUint32(13, Endian.little);
  final dataOffset = _fileHeaderLen + nameLength + typeLength;
  if (fileLength == 0 ||
      fileLength > maxFileBytes ||
      transmittedLength == 0 ||
      transmittedLength > maxFileBytes ||
      dataOffset + transmittedLength != container.length) {
    throw const FormatException(
        'The recovered file length does not match its header.');
  }

  final transmitted =
      Uint8List.fromList(Uint8List.sublistView(container, dataOffset));
  if (compression == compressionGzip) {
    if (transmitted.length < 18) {
      throw const FormatException('The recovered gzip payload is incomplete.');
    }
    final trailer = ByteData.sublistView(
        transmitted, transmitted.length - 4, transmitted.length);
    if (trailer.getUint32(0, Endian.little) != fileLength) {
      throw const FormatException(
          'The gzip payload length does not match its file header.');
    }
  }
  final bytes =
      compression == compressionGzip ? _gunzip(transmitted, fileLength) : transmitted;
  if (bytes.length != fileLength) {
    throw const FormatException(
        'The decompressed file length does not match its header.');
  }

  return OpticalFile(
    name: safeFileName(utf8.decode(
        Uint8List.sublistView(
            container, _fileHeaderLen, _fileHeaderLen + nameLength),
        allowMalformed: true)),
    type: utf8
            .decode(
                Uint8List.sublistView(
                    container, _fileHeaderLen + nameLength, dataOffset),
                allowMalformed: true)
            .isEmpty
        ? 'application/octet-stream'
        : utf8.decode(
            Uint8List.sublistView(
                container, _fileHeaderLen + nameLength, dataOffset),
            allowMalformed: true),
    sha256: Uint8List.fromList(Uint8List.sublistView(container, 17, 49)),
    bytes: bytes,
    compression: compression,
    transmittedSize: transmittedLength,
  );
}

bool verifyFile(OpticalFile file) {
  final actual = _digest(file.bytes);
  for (int i = 0; i < actual.length; i++) {
    if (actual[i] != file.sha256[i]) return false;
  }
  return true;
}

class FrameHeader {
  final int sessionId;
  final int seq;
  final int k;
  final int blockLen;
  final int totalLen;
  final int payloadFnv;

  /// Feature bits (see [flagEncrypted] and [criticalFlags]). Required: the
  /// wire always carries this byte. Nothing this build sends sets any bit.
  final int flags;
  FrameHeader({
    required this.sessionId,
    required this.seq,
    required this.k,
    required this.blockLen,
    required this.totalLen,
    required this.payloadFnv,
    required this.flags,
  });
}

/// Why a frame did not parse — the difference between "point the camera
/// somewhere else" and "one of these two devices needs an update".
sealed class FrameVerdict {
  const FrameVerdict();
}

class FrameVerdictOk extends FrameVerdict {
  const FrameVerdictOk();
}

class FrameVerdictForeign extends FrameVerdict {
  const FrameVerdictForeign();
}

class FrameVerdictOlderSender extends FrameVerdict {
  final int version;
  const FrameVerdictOlderSender(this.version);
  @override
  bool operator ==(Object other) =>
      other is FrameVerdictOlderSender && other.version == version;
  @override
  int get hashCode => Object.hash(runtimeType, version);
}

class FrameVerdictNewerSender extends FrameVerdict {
  final int version;
  const FrameVerdictNewerSender(this.version);
  @override
  bool operator ==(Object other) =>
      other is FrameVerdictNewerSender && other.version == version;
  @override
  int get hashCode => Object.hash(runtimeType, version);
}

class FrameVerdictUnsupportedFlags extends FrameVerdict {
  final int flags;
  const FrameVerdictUnsupportedFlags(this.flags);
  @override
  bool operator ==(Object other) =>
      other is FrameVerdictUnsupportedFlags && other.flags == flags;
  @override
  int get hashCode => Object.hash(runtimeType, flags);
}

class FrameVerdictMalformed extends FrameVerdict {
  const FrameVerdictMalformed();
}

Uint8List packFrame(FrameHeader h, Uint8List block) {
  final out = Uint8List(headerLen + block.length);
  final dv = ByteData.view(out.buffer);
  dv.setUint8(0, _magic0);
  dv.setUint8(1, _magic1);
  dv.setUint8(2, wireVersion);
  dv.setUint8(3, h.flags);
  dv.setUint16(4, h.sessionId, Endian.little);
  dv.setUint32(6, h.seq, Endian.little);
  dv.setUint16(10, h.k, Endian.little);
  dv.setUint16(12, h.blockLen, Endian.little);
  dv.setUint32(14, h.totalLen, Endian.little);
  dv.setUint32(18, h.payloadFnv, Endian.little);
  out.setRange(headerLen, headerLen + block.length, block);
  return out;
}

/// Single owner of "is this frame ours, and can we decode it?".
FrameVerdict classifyFrame(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != _magic0) return const FrameVerdictForeign();
  if (bytes[1] != _magic1) {
    final legacy = _legacyMagic1[bytes[1]];
    return legacy == null
        ? const FrameVerdictForeign()
        : FrameVerdictOlderSender(legacy);
  }

  final version = bytes[2];
  if (version == 0) return const FrameVerdictMalformed();
  if (version != wireVersion) {
    return version > wireVersion
        ? FrameVerdictNewerSender(version)
        : FrameVerdictOlderSender(version);
  }

  final unknownCritical = bytes[3] & criticalFlags & ~_supportedFlags;
  if (unknownCritical != 0) {
    return FrameVerdictUnsupportedFlags(unknownCritical);
  }

  if (bytes.length <= headerLen) return const FrameVerdictMalformed();
  final dv = ByteData.sublistView(bytes);
  final k = dv.getUint16(10, Endian.little);
  final blockLen = dv.getUint16(12, Endian.little);
  final totalLen = dv.getUint32(14, Endian.little);
  if (k == 0 || blockLen == 0 || totalLen == 0) {
    return const FrameVerdictMalformed();
  }
  if (bytes.length != headerLen + blockLen) return const FrameVerdictMalformed();
  return const FrameVerdictOk();
}

/// English reference wording, pinned to the web catalog. The UI translates.
String? frameVerdictMessage(FrameVerdict verdict) {
  switch (verdict) {
    case FrameVerdictOlderSender(:final version):
      return 'That screen is sending an older Decimen format (v$version). Update the sending device.';
    case FrameVerdictNewerSender(:final version):
      return 'That screen is sending a newer Decimen format (v$version). Update this app to receive it.';
    case FrameVerdictUnsupportedFlags():
      return 'That stream uses a Decimen feature this version cannot read. Update this app to receive it.';
    default:
      return null;
  }
}

({FrameHeader header, Uint8List block})? parseFrame(Uint8List bytes) {
  if (classifyFrame(bytes) is! FrameVerdictOk) return null;
  final dv = ByteData.sublistView(bytes);
  final header = FrameHeader(
    sessionId: dv.getUint16(4, Endian.little),
    seq: dv.getUint32(6, Endian.little),
    k: dv.getUint16(10, Endian.little),
    blockLen: dv.getUint16(12, Endian.little),
    totalLen: dv.getUint32(14, Endian.little),
    payloadFnv: dv.getUint32(18, Endian.little),
    flags: dv.getUint8(3),
  );
  return (header: header, block: Uint8List.sublistView(bytes, headerLen));
}

/// Everything about a frame that has to hold constant for a decoder to keep
/// accepting frames into it. `seq` is deliberately absent — it is the one field
/// that varies within a stream.
///
/// Critical flag bits only. An ignorable bit that flips mid-stream must NOT
/// reset the decoder.
String streamIdentity(FrameHeader h) {
  final critical = h.flags & criticalFlags;
  return '${h.sessionId}:${h.k}:${h.blockLen}:${h.totalLen}:${h.payloadFnv}:$critical';
}

int fnv1a(List<int> bytes) {
  int h = 0x811c9dc5;
  for (int i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// splitmix32 — deterministic across engines (integer ops only).
int Function() splitmix32(int seed) {
  int s = seed & 0xffffffff;
  return () {
    s = (s + 0x9e3779b9) & 0xffffffff;
    int t = s ^ (s >>> 16);
    t = (t * 0x21f0aaad) & 0xffffffff;
    t = t ^ (t >>> 15);
    t = (t * 0x735a2d97) & 0xffffffff;
    t = t ^ (t >>> 15);
    return t & 0xffffffff;
  };
}
