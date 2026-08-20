import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/utils/cloud_document_format.dart';
import '../../../domain/entities/cloud_document.dart';
import '../../../infrastructure/http/graph_http_client.dart';
import 'cloud_drive_datasource.dart';

/// Fetches a SharePoint / OneDrive-for-Business document through Microsoft
/// Graph, for one account.
///
/// Graph resolves a *sharing URL* directly — `/shares/{u!encoded}/driveItem` —
/// which is the only route that covers every shape these links arrive in
/// (`/:w:/g/personal/…` share links, `/:x:/r/sites/…?d=w…` redirects, and plain
/// `/sites/Team/Shared Documents/Doc.docx` library paths). Picking a drive and
/// item id out of the URL by hand would only ever handle one of them.
class GraphDriveDatasourceImpl implements CloudDriveDatasource {
  GraphDriveDatasourceImpl({
    required GraphHttpClient client,
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
      final pdf = await _downloadContent(shareId, asPdf: true, allowNull: true);
      if (pdf != null) {
        return CloudDocument(
          name: name,
          contentType: 'application/pdf',
          bytes: pdf,
          convertedToPdf: true,
        );
      }
    }

    final bytes = await _downloadContent(shareId, asPdf: false, allowNull: false);
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
    String shareId, {
    required bool asPdf,
    required bool allowNull,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        '/shares/$shareId/driveItem/content',
        queryParameters: asPdf ? {'format': 'pdf'} : null,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (s) => s != null && s < 400,
        ),
      );

      final location = response.headers.value('location');
      if (location != null && location.isNotEmpty) {
        return await _downloadPreAuthenticated(location);
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

  Future<Uint8List> _downloadPreAuthenticated(String url) async {
    try {
      final response = await _preAuth.get<List<int>>(
        url,
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
