import 'dart:typed_data';

class LocalAttachment {
  LocalAttachment({
    this.path = '',
    required this.name,
    required this.mimeType,
    required this.bytes,
    this.isInline = false,
    this.contentId,
  });

  final String path;
  final String name;
  final String mimeType;
  // Bytes are read eagerly at drop time so no file-system access is needed
  // later when saving/sending (avoids Windows permission issues at save time).
  final Uint8List bytes;
  // When true, this attachment is an inline image referenced from the HTML body
  // by its [contentId] (cid: scheme). Not shown in the attachments chip list.
  final bool isInline;
  // Content-Id value used in the HTML body as `src="cid:{contentId}"`.
  final String? contentId;

  static String mimeTypeFromName(String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot >= 0 ? filename.substring(dot + 1).toLowerCase() : '';
    return const {
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain',
      'csv': 'text/csv',
      'html': 'text/html',
      'htm': 'text/html',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'bmp': 'image/bmp',
      'svg': 'image/svg+xml',
      'tiff': 'image/tiff',
      'tif': 'image/tiff',
      'webp': 'image/webp',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'zip': 'application/zip',
      'gz': 'application/gzip',
      'tar': 'application/x-tar',
      'json': 'application/json',
      'xml': 'application/xml',
      'rtf': 'application/rtf',
      'ics': 'text/calendar',
    }[ext] ??
        'application/octet-stream';
  }
}
