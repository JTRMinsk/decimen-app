// A text snippet rides the same optical container a file does — it is just
// UTF-8 bytes with a media type the receiver recognises.
//
// Ported from shared/snippet.ts.

import 'dart:convert';
import 'dart:typed_data';

import 'protocol.dart';

const String snippetMediaType = 'application/vnd.decimen.snippet';
const String snippetFileName = 'snippet.txt';
const int maxSnippetBytes = 4 * 1024 * 1024;
const String maxSnippetLabel = '4 MB';

bool isSnippet(OpticalFile file) {
  return file.type == snippetMediaType;
}

PackedOpticalFile packSnippet(String text) {
  if (text.trim().isEmpty) {
    throw const FormatException('Paste or type some text before sending.');
  }
  final bytes = Uint8List.fromList(utf8.encode(text));
  if (bytes.length > maxSnippetBytes) {
    throw FormatException('Text snippets are limited to $maxSnippetLabel.');
  }
  return packFile(snippetFileName, snippetMediaType, bytes);
}

/// Decode an already-unpacked, already-verified snippet container.
String snippetText(OpticalFile file) {
  if (!isSnippet(file)) {
    throw const FormatException('This stream is not a text snippet.');
  }
  try {
    return utf8.decode(file.bytes); // throws on malformed UTF-8
  } on FormatException {
    throw const FormatException('The recovered snippet is not valid UTF-8.');
  }
}
