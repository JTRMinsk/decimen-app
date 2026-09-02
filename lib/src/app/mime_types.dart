// A small, dependency-free extension → media-type map for the sender's file
// picker. The media type only drives the gzip-skip decision (see
// isPrecompressedType); a missing entry falls back to
// application/octet-stream, which is functionally correct but may run a gzip
// pass that ends up not shrinking the payload.

const Map<String, String> _mimeByExtension = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'svg': 'image/svg+xml',
  'heic': 'image/heic',
  'ico': 'image/x-icon',
  'tiff': 'image/tiff',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  '7z': 'application/x-7z-compressed',
  'rar': 'application/vnd.rar',
  'xz': 'application/x-xz',
  'bz2': 'application/x-bzip2',
  'apk': 'application/vnd.android.package-archive',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/plain',
  'csv': 'text/csv',
  'json': 'application/json',
  'xml': 'application/xml',
  'html': 'text/html',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xlsx':
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'odt': 'application/vnd.oasis.opendocument.text',
  'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  'epub': 'application/epub+zip',
  'wasm': 'application/wasm',
};

String mimeTypeForName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return 'application/octet-stream';
  final ext = name.substring(dot + 1).toLowerCase();
  return _mimeByExtension[ext] ?? 'application/octet-stream';
}
