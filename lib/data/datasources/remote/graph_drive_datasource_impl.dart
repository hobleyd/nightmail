import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/error/exceptions.dart';
import '../../../core/utils/cloud_document_format.dart';
import '../../../domain/entities/cloud_document.dart';
import '../../../domain/entities/cloud_file.dart';
import '../../../infrastructure/http/graph_http_client.dart';
import 'cloud_drive_datasource.dart';
import 'cloud_file_access_matcher.dart';

/// Fetches a SharePoint / OneDrive-for-Business document through Microsoft
/// Graph, for one account.
///
/// Graph resolves a *sharing URL* directly — `/shares/{u!encoded}/driveItem` —
/// which is the only route that covers every shape these links arrive in
/// (`/:w:/g/personal/…` share links, `/:x:/r/sites/…?d=w…` redirects, and plain
/// `/sites/Team/Shared Documents/Doc.docx` library paths). Picking a drive and
/// item id out of the URL by hand would only ever handle one of them.
///
/// The same class browses the account's own drive for the compose window
/// (`/me/drive`, `/drives/{id}/items/{id}`), for Microsoft 365 and a NightMail
/// Server alike — Nightware serves the caller's Nextcloud home as `/me/drive`
/// (its ADR 0008). Only [provider] tells them apart, for the two things it
/// does not serve: `sharedWithMe` and Microsoft Search.
class GraphDriveDatasourceImpl implements CloudDriveDatasource {
  GraphDriveDatasourceImpl({
    required GraphHttpClient client,
    this.accountId = '',
    this.provider = CloudDriveProvider.microsoft,
    Dio? preAuthClient,
  })  : _dio = client.dio,
        // A *separate*, interceptor-free Dio for pre-authenticated download
        // URLs. Graph answers a content request with a 302 to a short-lived
        // signed blob URL, and that URL rejects a request that also carries an
        // `Authorization` header ("only one authentication mechanism allowed").
        // Reusing the Graph client here — whose AuthInterceptor adds the header
        // to every request it sees — is exactly that mistake.
        _preAuth = preAuthClient ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 2),
            ));

  final Dio _dio;
  final Dio _preAuth;

  /// Stamped on every [CloudFile] this lists, so the item can find its way
  /// back to this account.
  final String accountId;
  final CloudDriveProvider provider;

  /// Pages of a folder listing followed before stopping: 2,000 items at the
  /// page size asked for, which is past what anyone scrolls a picker for.
  static const int _maxPages = 10;

  /// Documents beyond this are not previewed: the bytes are held in memory on
  /// the way to a temp file, and a reader who clicked a link is not waiting on
  /// a 200 MB download. The browser handles those better anyway.
  static const int maxDocumentBytes = 40 * 1024 * 1024;

  /// Encodes a sharing URL as Graph's `shares` id.
  ///
  /// `u!` followed by unpadded base64url — documented as "base64 the URL, strip
  /// `=`, replace `/` with `_` and `+` with `-`". Leaving the padding on is a
  /// 400 that reads like an unsupported link, which is why this is pinned by a
  /// test against Microsoft's own worked example.
  static String encodeSharingUrl(String url) {
    final b64 = base64Encode(utf8.encode(url));
    final trimmed = b64.replaceAll('=', '').replaceAll('/', '_').replaceAll('+', '-');
    return 'u!$trimmed';
  }

  @override
  Future<CloudDocument> fetchDocument(CloudDocumentLink link) async {
    final shareId = encodeSharingUrl(link.url);

    final Map<String, dynamic> item;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/shares/$shareId/driveItem',
        queryParameters: {r'$select': 'id,name,size,file,folder'},
      );
      item = response.data ?? const {};
    } on DioException catch (e) {
      throw _mapException(e);
    }

    if (item['folder'] != null) {
      throw const CloudDocumentNotPreviewableException(
          message: 'That link points at a folder');
    }

    final name = (item['name'] as String?)?.trim();
    if (name == null || name.isEmpty) {
      throw const ServerException(message: 'Graph returned no file name');
    }
    final contentType =
        (item['file'] as Map<String, dynamic>?)?['mimeType'] as String?;
    final size = (item['size'] as num?)?.toInt();

    final format = cloudDocumentFormatFor(name: name, contentType: contentType);
    if (format == null) {
      throw CloudDocumentNotPreviewableException(
          message: 'NightMail cannot preview $name');
    }
    if (size != null && size > maxDocumentBytes) {
      throw CloudDocumentNotPreviewableException(
          message: '$name is too large to preview');
    }

    // Office formats come back as a server-rendered PDF: higher fidelity than
    // the bundled JS viewer and it needs no LibreOffice on the machine. A
    // refused conversion (415, or a format Graph declines today) falls back to
    // the raw file, which OfficePreviewService can still show.
    if (format == CloudDocumentFormat.officeConvertible) {
      final pdf = await _downloadContent('/shares/$shareId/driveItem/content',
          asPdf: true, allowNull: true);
      if (pdf != null) {
        return CloudDocument(
          name: name,
          contentType: 'application/pdf',
          bytes: pdf,
          convertedToPdf: true,
        );
      }
    }

    final bytes = await _downloadContent('/shares/$shareId/driveItem/content',
        asPdf: false, allowNull: false);
    return CloudDocument(
      name: name,
      contentType: contentType ?? 'application/octet-stream',
      bytes: bytes!,
    );
  }

  /// Downloads `/driveItem/content`, following the 302 by hand.
  ///
  /// `followRedirects: false` is load-bearing: Dio would otherwise replay the
  /// `Authorization` header onto the signed blob URL Graph redirects to, which
  /// that URL refuses. Graph may also answer 200 with the bytes inline, so both
  /// are handled.
  ///
  /// [allowNull] returns null instead of throwing when a *conversion* is
  /// refused, so the caller can fall back to the raw file.
  Future<Uint8List?> _downloadContent(
    String path, {
    required bool asPdf,
    required bool allowNull,
    int maxBytes = maxDocumentBytes,
    String tooLargeMessage = 'That document is too large to preview',
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        path,
        queryParameters: asPdf ? {'format': 'pdf'} : null,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (s) => s != null && s < 400,
        ),
      );

      final location = response.headers.value('location');
      if (location != null && location.isNotEmpty) {
        return await _downloadPreAuthenticated(location,
            maxBytes: maxBytes, tooLargeMessage: tooLargeMessage);
      }
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const ServerException(message: 'The document came back empty');
      }
      return Uint8List.fromList(data);
    } on CloudDocumentNotPreviewableException {
      // About the document, not about the conversion — a fallback download
      // would only find the same thing, larger.
      rethrow;
    } catch (e) {
      // The whole attempt is abandoned, redirect leg included: a conversion
      // that fails anywhere along the way just means the raw file instead.
      if (allowNull) return null;
      if (e is DioException) throw _mapException(e);
      rethrow;
    }
  }

  Future<Uint8List> _downloadPreAuthenticated(
    String url, {
    required int maxBytes,
    required String tooLargeMessage,
  }) async {
    try {
      final response = await _preAuth.get<List<int>>(
        url,
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

  /// The Graph path addressing [file]: by drive when the item lives in a drive
  /// other than the caller's own (a SharePoint library, someone else's
  /// OneDrive), through `/me/drive` otherwise.
  String _itemPath(CloudFile file) => file.driveId != null
      ? '/drives/${Uri.encodeComponent(file.driveId!)}/items/'
          '${Uri.encodeComponent(file.id)}'
      : '/me/drive/items/${Uri.encodeComponent(file.id)}';

  @override
  Future<List<CloudFile>> listFiles({
    CloudFile? folder,
    CloudFileCollection collection = CloudFileCollection.myFiles,
  }) async {
    final String path;
    if (folder != null) {
      path = '${_itemPath(folder)}/children';
    } else if (collection == CloudFileCollection.sharedWithMe &&
        provider == CloudDriveProvider.microsoft) {
      path = '/me/drive/sharedWithMe';
    } else if (collection == CloudFileCollection.myFiles) {
      path = '/me/drive/root/children';
    } else {
      return const [];
    }
    final items = await _getAllPages(path, {r'$top': '200'});
    return _sorted(items.map(_fileFrom).whereType<CloudFile>());
  }

  @override
  Future<List<CloudFile>> searchFiles(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    // Microsoft Search reaches SharePoint and files shared with the user, not
    // just their own OneDrive, under the Files.Read.All the picker already
    // holds. A NightMail Server has no `/search/query`; its drive search is
    // the whole of its Nextcloud home anyway.
    if (provider == CloudDriveProvider.microsoft) {
      try {
        return await _microsoftSearch(q);
      } on ServerException catch (e) {
        debugPrint('[CloudFiles] /search/query refused (${e.statusCode}); '
            'searching the OneDrive alone');
      }
    }
    final escaped = Uri.encodeComponent(q.replaceAll("'", "''"));
    final items =
        await _getAllPages("/me/drive/root/search(q='$escaped')", const {}, maxPages: 2);
    return _sorted(items.map(_fileFrom).whereType<CloudFile>());
  }

  Future<List<CloudFile>> _microsoftSearch(String q) async {
    final Map<String, dynamic> body;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/search/query',
        data: {
          'requests': [
            {
              'entityTypes': ['driveItem'],
              'query': {'queryString': q},
              'from': 0,
              'size': 50,
            }
          ],
        },
      );
      body = response.data ?? const {};
    } on DioException catch (e) {
      throw _mapException(e);
    }
    final files = <CloudFile>[];
    for (final response in (body['value'] as List?) ?? const []) {
      if (response is! Map<String, dynamic>) continue;
      for (final container in (response['hitsContainers'] as List?) ?? const []) {
        if (container is! Map<String, dynamic>) continue;
        for (final hit in (container['hits'] as List?) ?? const []) {
          final resource = hit is Map<String, dynamic> ? hit['resource'] : null;
          if (resource is! Map<String, dynamic>) continue;
          final file = _fileFrom(resource, lenient: true);
          if (file != null) files.add(file);
        }
      }
    }
    return files;
  }

  /// GETs [path] and every `@odata.nextLink` after it, up to [maxPages].
  ///
  /// A next link is only followed on this account's own Graph host: Dio sends
  /// an absolute URL as-is, and the `AuthInterceptor` would put this account's
  /// token on it wherever it pointed.
  Future<List<Map<String, dynamic>>> _getAllPages(
    String path,
    Map<String, dynamic> queryParameters, {
    int maxPages = _maxPages,
  }) async {
    final out = <Map<String, dynamic>>[];
    final ownHost = Uri.tryParse(_dio.options.baseUrl)?.host;
    String? next = path;
    var query = queryParameters;
    for (var page = 0; next != null && page < maxPages; page++) {
      final Map<String, dynamic> body;
      try {
        final response = await _dio.get<Map<String, dynamic>>(next,
            queryParameters: query.isEmpty ? null : query);
        body = response.data ?? const {};
      } on DioException catch (e) {
        throw _mapException(e);
      }
      for (final item in (body['value'] as List?) ?? const []) {
        if (item is Map<String, dynamic>) out.add(item);
      }
      final link = body['@odata.nextLink'];
      next = link is String && Uri.tryParse(link)?.host == ownHost ? link : null;
      query = const {};
    }
    return out;
  }

  /// A driveItem as a [CloudFile], or null for something that is neither a
  /// file nor a folder (a OneNote notebook's `package`).
  ///
  /// A `sharedWithMe` entry is a pointer: the real item, and the drive it
  /// lives in, are under `remoteItem`. [lenient] is for search hits, whose
  /// resources do not always carry the `file` facet.
  CloudFile? _fileFrom(Map<String, dynamic> item, {bool lenient = false}) {
    final remote = item['remoteItem'];
    final source = remote is Map<String, dynamic> ? remote : item;
    final id = source['id'] as String?;
    if (id == null || id.isEmpty) return null;
    final isFolder = source['folder'] != null || item['folder'] != null;
    final file = source['file'] ?? item['file'];
    if (!isFolder && file == null && !lenient) return null;
    if (source['package'] != null || item['package'] != null) return null;
    final parent = source['parentReference'];
    final name = (item['name'] ?? source['name']) as String?;
    if (name == null || name.isEmpty) return null;
    return CloudFile(
      accountId: accountId,
      provider: provider,
      id: id,
      // An item in the caller's own drive is addressed through /me/drive; a
      // driveId is only needed for one that lives elsewhere, but carrying it
      // is never wrong, so keep whatever Graph gave.
      driveId: parent is Map<String, dynamic>
          ? parent['driveId'] as String?
          : null,
      name: name,
      isFolder: isFolder,
      size: ((source['size'] ?? item['size']) as num?)?.toInt(),
      mimeType: file is Map<String, dynamic> ? file['mimeType'] as String? : null,
      modified: DateTime.tryParse(
          (source['lastModifiedDateTime'] ?? item['lastModifiedDateTime'] ?? '')
              as String),
      webUrl: (source['webUrl'] ?? item['webUrl']) as String?,
    );
  }

  @override
  Future<CloudDocument> downloadFile(CloudFile file) async {
    if (file.isFolder) {
      throw const CloudDocumentNotPreviewableException(
          message: 'A folder cannot be attached');
    }
    final size = file.size;
    if (size != null && size > cloudAttachmentMaxBytes) {
      throw CloudDocumentNotPreviewableException(
          message: '${file.name} is too large to attach — link it instead');
    }
    final bytes = await _downloadContent(
      '${_itemPath(file)}/content',
      asPdf: false,
      allowNull: false,
      maxBytes: cloudAttachmentMaxBytes,
      tooLargeMessage: '${file.name} is too large to attach — link it instead',
    );
    return CloudDocument(
      name: file.name,
      contentType: file.mimeType ?? 'application/octet-stream',
      bytes: bytes!,
    );
  }

  @override
  Future<CloudFileAccess> checkAccess(
    CloudFile file,
    List<String> recipients, {
    required Set<String> organizationDomains,
  }) async {
    final List<Map<String, dynamic>> permissions;
    try {
      permissions = await _getAllPages('${_itemPath(file)}/permissions',
          const {}, maxPages: 3);
    } on ServerException catch (e) {
      // Only someone who can manage the item may list its permissions. A file
      // shared with the sender read-only lands here: nothing to check, and
      // nothing they could share either.
      if (e.statusCode == 403 || e.statusCode == 404) {
        debugPrint('[CloudFiles] permissions of ${file.name}: '
            'HTTP ${e.statusCode}; not checking');
        return const CloudFileAccess(recipientsWithoutAccess: [], canShare: false);
      }
      rethrow;
    }
    final matcher =
        CloudFileAccessMatcher(organizationDomains: organizationDomains);
    for (final permission in permissions) {
      matcher.addGraphPermission(permission);
    }
    return CloudFileAccess(
      recipientsWithoutAccess: matcher.uncovered(recipients),
      anyoneLinkUrl: matcher.anyoneLinkUrl,
    );
  }

  @override
  Future<CloudShareResult> shareFile(
      CloudFile file, List<String> recipients) async {
    // One recipient per request: Graph fails the whole invite over one
    // address it will not share with (an external one the tenant's policy
    // blocks, a Nightware address that is not a Nextcloud user), and the
    // sender needs to know which.
    final failed = <String, String>{};
    for (final recipient in recipients) {
      try {
        await _dio.post<Map<String, dynamic>>(
          '${_itemPath(file)}/invite',
          data: {
            'recipients': [
              {'email': recipient}
            ],
            'requireSignIn': true,
            // The message carrying the link is the notification.
            'sendInvitation': false,
            'roles': ['read'],
          },
        );
      } on DioException catch (e) {
        final mapped = _mapException(e);
        if (mapped is NetworkException || mapped is AuthException) throw mapped;
        failed[recipient] = mapped is ServerException
            ? mapped.message
            : 'Sharing failed';
      }
    }
    return CloudShareResult(failed: failed);
  }

  static List<CloudFile> _sorted(Iterable<CloudFile> files) =>
      files.toList()
        ..sort((a, b) {
          if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

  Exception _mapException(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }
    final statusCode = e.response?.statusCode;
    if (statusCode == 401) {
      return const AuthException(message: 'Authentication required');
    }
    return ServerException(
      message: _errorMessage(e) ??
          (statusCode != null ? 'Server error ($statusCode)' : 'Request failed'),
      statusCode: statusCode,
    );
  }

  /// Graph's own error text, when the response body carries any. The response
  /// is bytes on the download paths, so it has to be decoded by hand.
  String? _errorMessage(DioException e) {
    final data = e.response?.data;
    try {
      final Map<String, dynamic>? json = switch (data) {
        Map<String, dynamic> map => map,
        List<int> bytes =>
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>?,
        String text => jsonDecode(text) as Map<String, dynamic>?,
        _ => null,
      };
      final error = json?['error'];
      if (error is Map<String, dynamic>) return error['message'] as String?;
    } catch (_) {}
    return null;
  }
}
