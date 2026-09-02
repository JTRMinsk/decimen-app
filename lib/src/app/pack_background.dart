// Runs packFile (SHA-256 + optional gzip) off the UI thread. A 64 MB file
// takes a real chunk of CPU, and blocking the isolate that also paints the QR
// stream would stall it.

import 'package:flutter/foundation.dart';

import '../protocol/protocol.dart';

Future<PackedOpticalFile> packFileInBackground(
  String name,
  String type,
  Uint8List bytes,
) async {
  final result = await compute(_packEntry, <Object>[name, type, bytes]);
  return PackedOpticalFile(
    container: result[0] as Uint8List,
    compression: result[1] as String,
    originalSize: result[2] as int,
    transmittedSize: result[3] as int,
  );
}

List<Object> _packEntry(List<Object> args) {
  final packed =
      packFile(args[0] as String, args[1] as String, args[2] as Uint8List);
  return [
    packed.container,
    packed.compression,
    packed.originalSize,
    packed.transmittedSize,
  ];
}
