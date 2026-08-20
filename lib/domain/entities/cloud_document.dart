import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// Which cloud service holds a document — read off the link, never off the
/// mailbox the link arrived in. A OneDrive link in Gmail and a Drive link in
/// Exchange are both ordinary.
enum CloudDriveProvider { microsoft, google }

/// A link in a message body that names a single cloud document.
///
/// Produced by `parseCloudDocumentLink` (`core/utils/cloud_document_link.dart`),
/// which is the only thing that decides whether a URL is one of these.
class CloudDocumentLink extends Equatable {
  const CloudDocumentLink({
    required this.provider,
    required this.url,
    this.fileId,
  });

  final CloudDriveProvider provider;

  /// The link exactly as it appeared in the body. Microsoft needs this whole:
  /// Graph resolves a sharing URL directly rather than an id.
  final String url;

  /// Google Drive's file id, picked out of the URL. Null for
  /// [CloudDriveProvider.microsoft], which has no equivalent in the link.
  final String? fileId;

  @override
  List<Object?> get props => [provider, url, fileId];
}

/// A cloud document fetched and ready to preview.
///
/// [bytes] is what the preview surface writes to a temp file, exactly as
/// `DownloadAttachment` hands over attachment bytes — the two share the whole
/// preview path from there on.
class CloudDocument extends Equatable {
  const CloudDocument({
    required this.name,
    required this.contentType,
    required this.bytes,
    this.convertedToPdf = false,
  });

  final String name;
  final String contentType;
  final Uint8List bytes;

  /// True when the provider converted the file to PDF for us (Graph
  /// `content?format=pdf`, Drive `export?mimeType=application/pdf`). The name
  /// still carries the original extension, so the preview needs telling.
  final bool convertedToPdf;

  @override
  List<Object?> get props => [name, contentType, bytes.length, convertedToPdf];
}
