import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// For a chat image on a public host (a Teams GIF or sticker, a Google
/// profile photo): no base URL, no interceptors — so never the account's
/// token, which only goes to the account's own server.
final publicImageClient = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 30),
));

/// The largest chat image or photo shown; anything bigger reads "[image]".
const maxChatImageBytes = 15 * 1024 * 1024;

/// [url]'s bytes when it answers with an image, else null — a missing photo
/// (404), a refused one, an HTML error page or a network failure alike.
/// Chat images are decoration: none of that is an error worth showing, but
/// each miss is logged (host, status, type — never the token) so a picture
/// that never appears can be told apart from one that was never asked for.
///
/// An answer typed as something other than `image/*` still counts when its
/// bytes start like a picture: Google's media download serves an uploaded
/// screenshot as a binary blob, not under the attachment's own type.
Future<Uint8List?> fetchImageBytes(
  Dio dio,
  String url, {
  Map<String, dynamic>? query,
}) async {
  try {
    final r = await dio.get<List<int>>(
      url,
      queryParameters: query,
      options: Options(
        responseType: ResponseType.bytes,
        // Not the API client's `application/json`: this asks for the bytes.
        headers: {'Accept': 'image/*,*/*;q=0.8'},
      ),
    );
    final type = r.headers.value(Headers.contentTypeHeader) ?? '';
    final data = r.data;
    if (data == null ||
        data.isEmpty ||
        data.length > maxChatImageBytes ||
        (!type.startsWith('image/') && !looksLikeImage(data))) {
      debugPrint('[ChatImage] ${r.requestOptions.uri.host} ${r.statusCode} '
          '"$type" ${data?.length ?? 0} bytes: not shown');
      return null;
    }
    return data is Uint8List ? data : Uint8List.fromList(data);
  } on DioException catch (e) {
    debugPrint('[ChatImage] ${e.requestOptions.uri.host} '
        '${e.response?.statusCode ?? e.type.name}: not shown');
    return null;
  } catch (e) {
    debugPrint('[ChatImage] ${e.runtimeType}: not shown');
    return null;
  }
}

/// Whether [b] starts with the signature of a format the image decoder
/// reads: PNG, JPEG, GIF, WebP, BMP or HEIF/AVIF (an `ftyp` box).
@visibleForTesting
bool looksLikeImage(List<int> b) {
  bool at(int offset, List<int> sig) {
    if (b.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[offset + i] != sig[i]) return false;
    }
    return true;
  }

  return at(0, const [0x89, 0x50, 0x4E, 0x47]) ||
      at(0, const [0xFF, 0xD8, 0xFF]) ||
      at(0, 'GIF8'.codeUnits) ||
      (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) ||
      at(0, 'BM'.codeUnits) ||
      at(4, 'ftyp'.codeUnits);
}
