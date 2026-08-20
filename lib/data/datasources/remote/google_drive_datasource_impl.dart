import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/utils/cloud_document_format.dart';
import '../../../domain/entities/cloud_document.dart';
import '../../../infrastructure/http/google_drive_http_client.dart';
import 'cloud_drive_datasource.dart';

/// Fetches a Google Drive document, for one account.
///
/// Two shapes of file, fetched two different ways:
///
/// * A **Google editor file** (Docs/Sheets/Slides/Drawings) has no bytes of its
///   own — it is only ever an export. `files/{id}/export?mimeType=application/pdf`
///   is the one that renders like the real thing, and it is capped at 10 MB by
///   Google, past which the link goes to the browser.
/// * **Anything uploaded** downloads as itself (`alt=media`). Drive will not
///   convert those without write access (copy-then-export), so an uploaded
///   `.docx` is handed to `OfficePreviewService` locally rather than converted.
class GoogleDriveDatasourceImpl implements CloudDriveDatasource {
  GoogleDriveDatasourceImpl({required GoogleDriveHttpClient client})
      : _dio = client.dio;

  final Dio _dio;

  /// Matches `GraphDriveDatasourceImpl.maxDocumentBytes`: the bytes pass
  /// through memory on the way to a temp file.
  static const int maxDocumentBytes = 40 * 1024 * 1024;

  static const _googlePrefix = 'application/vnd.google-apps.';

  /// The editor types that export to PDF. Everything else under
  /// `application/vnd.google-apps.` — folder, form, site, script, map — is not
  /// a document and has no export.
  static const _exportableEditorTypes = <String>{
    'document',
    'spreadsheet',
    'presentation',
    'drawing',
  };

  @override
  Future<CloudDocument> fetchDocument(CloudDocumentLink link) async {
    final fileId = link.fileId;
    if (fileId == null || fileId.isEmpty) {
      throw const CloudDocumentNotPreviewableException(
          message: 'That link does not name a Drive file');
    }
    return _fetch(fileId, followShortcut: true);
  }

  Future<CloudDocument> _fetch(String fileId,
      {required bool followShortcut}) async {
    final meta = await _metadata(fileId);
    final mimeType = (meta['mimeType'] as String?) ?? '';
    final name = ((meta['name'] as String?) ?? '').trim();

    // A shortcut is a pointer, not a file. Resolve it once — a shortcut to a
    // shortcut is not a thing Drive creates.
    if (mimeType == '${_googlePrefix}shortcut' && followShortcut) {
      final target = (meta['shortcutDetails'] as Map<String, dynamic>?)?[
          'targetId'] as String?;
      if (target == null || target.isEmpty) {
        throw const CloudDocumentNotPreviewableException(
            message: 'That shortcut does not point anywhere readable');
      }
      return _fetch(target, followShortcut: false);
    }

    if (name.isEmpty) {
      throw const ServerException(message: 'Drive returned no file name');
    }

    if (mimeType.startsWith(_googlePrefix)) {
      final kind = mimeType.substring(_googlePrefix.length);
      if (!_exportableEditorTypes.contains(kind)) {
        throw CloudDocumentNotPreviewableException(
            message: 'NightMail cannot preview $name');
      }
      final bytes = await _download(
        '/files/$fileId/export',
        queryParameters: {
          'mimeType': 'application/pdf',
          'supportsAllDrives': 'true',
        },
      );
      // The exported name has no extension of its own — Drive titles carry
      // none for editor files — and `convertedToPdf` is what tells the preview
      // to treat it as a PDF regardless.
      return CloudDocument(
        name: name,
        contentType: 'application/pdf',
        bytes: bytes,
        convertedToPdf: true,
      );
    }

    final format = cloudDocumentFormatFor(name: name, contentType: mimeType);
    if (format == null) {
      throw CloudDocumentNotPreviewableException(
          message: 'NightMail cannot preview $name');
    }
    final size = int.tryParse((meta['size'] as String?) ?? '');
    if (size != null && size > maxDocumentBytes) {
      throw CloudDocumentNotPreviewableException(
          message: '$name is too large to preview');
    }

    final bytes = await _download(
      '/files/$fileId',
      queryParameters: {'alt': 'media', 'supportsAllDrives': 'true'},
    );
    return CloudDocument(
      name: name,
      contentType: mimeType.isEmpty ? 'application/octet-stream' : mimeType,
      bytes: bytes,
    );
  }

  Future<Map<String, dynamic>> _metadata(String fileId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/files/$fileId',
        queryParameters: {
          'fields': 'id,name,mimeType,size,shortcutDetails/targetId',
          'supportsAllDrives': 'true',
        },
      );
      return response.data ?? const {};
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  Future<Uint8List> _download(
    String path, {
    required Map<String, dynamic> queryParameters,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        path,
        queryParameters: queryParameters,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const ServerException(message: 'The document came back empty');
      }
      if (data.length > maxDocumentBytes) {
        throw const CloudDocumentNotPreviewableException(
            message: 'That document is too large to preview');
      }
      return Uint8List.fromList(data);
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  Exception _mapException(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }
    final statusCode = e.response?.statusCode;
    final reason = _errorReason(e);
    if (statusCode == 401) {
      return const AuthException(message: 'Authentication required');
    }
    // A document past Drive's export ceiling is a settled "not here", not a
    // server error: the browser opens it fine and that is where it should go.
    if (reason == 'exportSizeLimitExceeded') {
      return const CloudDocumentNotPreviewableException(
          message: 'That document is too large for Drive to export');
    }
    return ServerException(
      message: _errorMessage(e) ??
          (statusCode != null ? 'Server error ($statusCode)' : 'Request failed'),
      statusCode: statusCode,
    );
  }

  Map<String, dynamic>? _errorJson(DioException e) {
    final data = e.response?.data;
    try {
      return switch (data) {
        Map<String, dynamic> map => map,
        List<int> bytes =>
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>?,
        String text => jsonDecode(text) as Map<String, dynamic>?,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  String? _errorMessage(DioException e) {
    final error = _errorJson(e)?['error'];
    if (error is Map<String, dynamic>) return error['message'] as String?;
    return null;
  }

  String? _errorReason(DioException e) {
    final error = _errorJson(e)?['error'];
    if (error is! Map<String, dynamic>) return null;
    final errors = error['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      if (first is Map<String, dynamic>) return first['reason'] as String?;
    }
    return null;
  }
}
