// Ported verbatim from tests/format.test.ts.

import 'package:flutter_test/flutter_test.dart';

import 'package:decimen_app/src/protocol/format.dart';
import 'package:decimen_app/src/protocol/protocol.dart';

void main() {
  test('byte counts read the way a person would say them', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(1024 * 1024 - 1), '1024.0 KB');
    expect(formatBytes(1024 * 1024), '1.0 MB');
    expect(formatBytes(150323855), '143.4 MB');
  });

  test('the file size limit and its label agree', () {
    expect(maxFileLabel, '64 MB');
    expect(formatBytes(maxFileBytes), '64.0 MB');
  });
}
