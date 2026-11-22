import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/utils/cloud_document_format.dart';
import '../../../domain/entities/cloud_document.dart';
import '../../../domain/entities/cloud_file.dart';
import '../../../infrastructure/http/google_drive_http_client.dart';
import 'cloud_drive_datasource.dart';
import 'cloud_file_access_matcher.dart';

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
  GoogleDriveDatasourceImpl({
    required GoogleDriveHttpClient client,
    this.accountId = '',
  }) : _dio = client.dio;

  final Dio _dio;

  /// Stamped on every [CloudFile] this lists.
  final String accountId;

  static const _folderMimeType = 'application/vnd.google-apps.folder';

  /// What attaching a Google editor file exports it as: the Office format a
  /// recipient can open without a Google account. A Drawing has no Office
  /// equivalent, so it goes as PDF.
  static const _attachExports = <String, (String, String)>{
    'document': (
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'docx'
    ),
    'spreadsheet': (
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'xlsx'
    ),
    'presentation': (
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'pptx'
    ),
    'drawing': ('application/pdf', 'pdf'),
  };

  static const _listFields = 'nextPageToken, files(id, name, mimeType, size, '
      'modifiedTime, webViewLink, shortcutDetails(targetId, targetMimeType))';

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
    int maxBytes = maxDocumentBytes,
    String tooLargeMessage = 'That document is too large to preview',
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
      if (data.length > maxBytes) {
        throw CloudDocumentNotPreviewableException(message: tooLargeMessage);
      }
      return Uint8List.fromList(data);
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Browsing, attaching and sharing (the compose window's cloud picker)
  // ---------------------------------------------------------------------------

  @override
  Future<List<CloudFile>> listFiles({
    CloudFile? folder,
    CloudFileCollection collection = CloudFileCollection.myFiles,
  }) async {
    if (folder != null) {
      return _listQuery("'${_escape(folder.id)}' in parents and trashed = false");
    }
    return switch (collection) {
      CloudFileCollection.myFiles =>
        _listQuery("'root' in parents and trashed = false"),
      CloudFileCollection.sharedWithMe =>
        _listQuery('sharedWithMe = true and trashed = false'),
      CloudFileCollection.sharedDrives => _listSharedDrives(),
    };
  }

  @override
  Future<List<CloudFile>> searchFiles(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    return _listQuery("name contains '${_escape(q)}' and trashed = false",
        maxPages: 2, orderBy: null);
  }

  /// Drive's query language quotes with `'` and escapes with `\`.
  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  Future<List<CloudFile>> _listQuery(
    String q, {
    int maxPages = 10,
    String? orderBy = 'folder,name_natural',
  }) async {
    final files = <CloudFile>[];
    String? pageToken;
    for (var page = 0; page < maxPages; page++) {
      final Map<String, dynamic> body;
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          '/files',
          queryParameters: {
            'q': q,
            'fields': _listFields,
            'pageSize': '200',
            'orderBy': ?orderBy,
            'supportsAllDrives': 'true',
            'includeItemsFromAllDrives': 'true',
            'corpora': 'allDrives',
            'pageToken': ?pageToken,
          },
        );
        body = response.data ?? const {};
      } on DioException catch (e) {
        throw _mapException(e);
      }
      for (final item in (body['files'] as List?) ?? const []) {
        if (item is! Map<String, dynamic>) continue;
        final file = _fileFrom(item);
        if (file != null) files.add(file);
      }
      pageToken = body['nextPageToken'] as String?;
      if (pageToken == null || pageToken.isEmpty) break;
    }
    return files;
  }

  /// The shared drives the account belongs to, each as a folder: a shared
  /// drive's id is also its root folder's, so `'{id}' in parents` lists it.
  Future<List<CloudFile>> _listSharedDrives() async {
    final Map<String, dynamic> body;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/drives',
        queryParameters: {'pageSize': '100', 'fields': 'drives(id, name)'},
      );
      body = response.data ?? const {};
    } on DioException catch (e) {
      throw _mapException(e);
    }
    return [
      for (final drive in (body['drives'] as List?) ?? const [])
        if (drive is Map<String, dynamic> && drive['id'] is String)
          CloudFile(
            accountId: accountId,
            provider: CloudDriveProvider.google,
            id: drive['id'] as String,
            name: (drive['name'] as String?) ?? 'Shared drive',
            isFolder: true,
          ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// A Drive file as a [CloudFile]. A shortcut stands in for its target —
  /// which is what opening, attaching or sharing it means — keeping the
  /// shortcut's own link.
  CloudFile? _fileFrom(Map<String, dynamic> item) {
    var id = item['id'] as String?;
    var mimeType = (item['mimeType'] as String?) ?? '';
    final name = ((item['name'] as String?) ?? '').trim();
    if (id == null || name.isEmpty) return null;
    if (mimeType == '${_googlePrefix}shortcut') {
      final details = item['shortcutDetails'];
      if (details is! Map<String, dynamic>) return null;
      id = details['targetId'] as String?;
      mimeType = (details['targetMimeType'] as String?) ?? '';
      if (id == null) return null;
    }
    return CloudFile(
      accountId: accountId,
      provider: CloudDriveProvider.google,
      id: id,
      name: name,
      isFolder: mimeType == _folderMimeType,
      size: int.tryParse((item['size'] as String?) ?? ''),
      mimeType: mimeType.isEmpty ? null : mimeType,
      modified: DateTime.tryParse((item['modifiedTime'] as String?) ?? ''),
      webUrl: item['webViewLink'] as String?,
    );
  }

  @override
  Future<CloudDocument> downloadFile(CloudFile file) async {
    if (file.isFolder) {
      throw const CloudDocumentNotPreviewableException(
          message: 'A folder cannot be attached');
    }
    final tooLarge = '${file.name} is too large to attach — link it instead';
    final mimeType = file.mimeType ?? '';
    if (mimeType.startsWith(_googlePrefix)) {
      final export = _attachExports[mimeType.substring(_googlePrefix.length)];
      if (export == null) {
        throw CloudDocumentNotPreviewableException(
            message: '${file.name} cannot be attached — link it instead');
      }
      final (exportType, extension) = export;
      final bytes = await _download(
        '/files/${file.id}/export',
        queryParameters: {'mimeType': exportType},
        maxBytes: cloudAttachmentMaxBytes,
        tooLargeMessage: tooLarge,
      );
      final suffix = '.$extension';
      return CloudDocument(
        name: file.name.toLowerCase().endsWith(suffix)
            ? file.name
            : '${file.name}$suffix',
        contentType: exportType,
        bytes: bytes,
      );
    }
    final size = file.size;
    if (size != null && size > cloudAttachmentMaxBytes) {
      throw CloudDocumentNotPreviewableException(message: tooLarge);
    }
    final bytes = await _download(
      '/files/${file.id}',
      queryParameters: {'alt': 'media', 'supportsAllDrives': 'true'},
      maxBytes: cloudAttachmentMaxBytes,
      tooLargeMessage: tooLarge,
    );
    return CloudDocument(
      name: file.name,
      contentType: mimeType.isEmpty ? 'application/octet-stream' : mimeType,
      bytes: bytes,
    );
  }

  @override
  Future<CloudFileAccess> checkAccess(
    CloudFile file,
    List<String> recipients, {
    required Set<String> organizationDomains,
  }) async {
    final Map<String, dynamic> meta;
    final List permissions;
    try {
      meta = (await _dio.get<Map<String, dynamic>>(
            '/files/${file.id}',
            queryParameters: {
              'fields': 'webViewLink, capabilities(canShare)',
              'supportsAllDrives': 'true',
            },
          ))
              .data ??
          const {};
      // permissions.list rather than the file's `permissions` field: that
      // field is never filled in for an item in a shared drive.
      permissions = (await _dio.get<Map<String, dynamic>>(
                '/files/${file.id}/permissions',
                queryParameters: {
                  'fields': 'permissions(type, role, emailAddress, domain)',
                  'supportsAllDrives': 'true',
                },
              ))
                  .data?['permissions'] as List? ??
          const [];
    } on DioException catch (e) {
      final mapped = _mapException(e);
      // A reader may not list a file's permissions. Nothing to check, and —
      // being a reader — nothing they could share.
      if (mapped is ServerException &&
          (mapped.statusCode == 403 || mapped.statusCode == 404)) {
        return const CloudFileAccess(recipientsWithoutAccess: [], canShare: false);
      }
      throw mapped;
    }
    final webViewLink = meta['webViewLink'] as String? ?? file.webUrl;
    final matcher =
        CloudFileAccessMatcher(organizationDomains: organizationDomains);
    for (final permission in permissions) {
      if (permission is Map<String, dynamic>) {
        matcher.addDrivePermission(permission, webViewLink: webViewLink);
      }
    }
    final capabilities = meta['capabilities'];
    return CloudFileAccess(
      recipientsWithoutAccess: matcher.uncovered(recipients),
      anyoneLinkUrl: matcher.anyoneLinkUrl,
      canShare: capabilities is Map<String, dynamic>
          ? capabilities['canShare'] != false
          : true,
    );
  }

  @override
  Future<CloudShareResult> shareFile(
      CloudFile file, List<String> recipients) async {
    final failed = <String, String>{};
    for (final recipient in recipients) {
      try {
        await _createReaderPermission(file.id, recipient, notify: false);
      } on DioException catch (first) {
        var error = first;
        // Drive will not grant an address with no Google account silently —
        // `invalidSharingRequest`, "you must check the 'Notify people' box" —
        // so that one recipient gets Google's own invitation as well.
        if (_errorReason(first) == 'invalidSharingRequest') {
          try {
            await _createReaderPermission(file.id, recipient, notify: true);
            continue;
          } on DioException catch (retry) {
            error = retry;
          }
        }
        final mapped = _mapException(error);
        if (mapped is NetworkException || mapped is AuthException) throw mapped;
        failed[recipient] =
            mapped is ServerException ? mapped.message : 'Sharing failed';
      }
    }
    return CloudShareResult(failed: failed);
  }

  Future<void> _createReaderPermission(String fileId, String email,
      {required bool notify}) async {
    await _dio.post<Map<String, dynamic>>(
      '/files/$fileId/permissions',
      queryParameters: {
        'supportsAllDrives': 'true',
        'sendNotificationEmail': '$notify',
      },
      data: {'type': 'user', 'role': 'reader', 'emailAddress': email},
    );
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
