/// What can be done with a cloud document once it is known — one rule, shared
/// by the two drive datasources (which decide whether to ask the provider for a
/// PDF, download the file as it is, or refuse) and by the reading pane (which
/// decides which preview surface to draw). Keeping them apart is how a file
/// gets downloaded and then found to be unpreviewable, which is a wasted
/// download and a dead end for the reader.
library;

enum CloudDocumentFormat {
  /// Already a PDF — download and show it in the webview.
  pdf,

  /// A raster image — download and show it in the image preview.
  image,

  /// An Office-family document the provider can render to PDF for us. Falls
  /// back to `OfficePreviewService` (the bundled JS viewer, or LibreOffice) if
  /// the conversion is refused.
  officeConvertible,

  /// Plain text, which the webview renders as-is from a file URL.
  plainText,
}

/// Formats Microsoft Graph will convert to PDF (`content?format=pdf`), which
/// is also the set Google Drive can print for a binary upload. Everything here
/// is an Office or OpenDocument format — the conversion is Office's own.
const _officeExtensions = <String>{
  'csv', 'doc', 'docx', 'odp', 'ods', 'odt', 'pot', 'potm', 'potx',
  'pps', 'ppsx', 'ppt', 'pptm', 'pptx', 'rtf', 'xls', 'xlsx',
};

const _imageExtensions = <String>{
  'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic',
};

const _plainTextExtensions = <String>{'txt', 'log', 'md'};

/// The preview route for a document, or null when there is none — in which
/// case the link belongs in the browser after all, and no bytes should be
/// fetched. SVG is deliberately absent: the attachment path excludes it too.
CloudDocumentFormat? cloudDocumentFormatFor({
  required String name,
  String? contentType,
}) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  final ct = (contentType ?? '').toLowerCase();

  if (ext == 'pdf' || ct.contains('pdf')) return CloudDocumentFormat.pdf;
  if (_imageExtensions.contains(ext) ||
      (ct.startsWith('image/') && !ct.contains('svg'))) {
    return CloudDocumentFormat.image;
  }
  if (_officeExtensions.contains(ext)) {
    return CloudDocumentFormat.officeConvertible;
  }
  if (_plainTextExtensions.contains(ext) || ct.startsWith('text/plain')) {
    return CloudDocumentFormat.plainText;
  }
  return null;
}
