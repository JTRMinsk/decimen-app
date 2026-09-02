// Byte counts for humans. Deliberately coarse — these land in a status line
// next to a filename, not in a report.
//
// Ported from shared/format.ts.

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
