// Ported verbatim from tests/snippet.test.ts.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:decimen_app/src/protocol/protocol.dart';
import 'package:decimen_app/src/protocol/snippet.dart';

String _repeat(String s, int n) => List.filled(n, s).join();

Matcher _formatException(String fragment) => throwsA(
    isA<FormatException>().having((e) => e.message, 'message', contains(fragment)));

void main() {
  test('a text snippet survives the optical container', () {
    const text = 'ssh-ed25519 AAAAC3Nz… evan@laptop\nand a second line.';
    final packed = packSnippet(text);
    final file = unpackFile(packed.container);

    expect(verifyFile(file), isTrue);
    expect(isSnippet(file), isTrue);
    expect(snippetText(file), text);
  });

  test('the receiver tells a snippet apart from an ordinary file', () {
    final file = unpackFile(packFile(
        'notes.txt', 'text/plain', Uint8List.fromList(utf8.encode('hello'))).container);

    expect(isSnippet(file), isFalse);
    expect(() => snippetText(file), _formatException('not a text snippet'));
  });

  test('empty snippets are rejected', () {
    expect(() => packSnippet('  \n\t '), _formatException('Paste or type some text'));
  });

  test('snippets are capped, and the cap is measured in UTF-8 bytes', () {
    expect(() => packSnippet(_repeat('x', maxSnippetBytes + 1)),
        _formatException('limited to $maxSnippetLabel'));

    // "あ" is one UTF-16 unit but three UTF-8 bytes.
    expect(
        () => packSnippet(_repeat('あ', (maxSnippetBytes / 3).ceil() + 1)),
        _formatException('limited to $maxSnippetLabel'));
  });

  test('long snippets compress before they are transmitted', () {
    final packed = packSnippet(_repeat('the same sentence over and over. ', 2000));

    expect(packed.compression, 'gzip');
    expect(packed.transmittedSize < packed.originalSize, isTrue);
  });
}
