import 'dart:typed_data';

import 'package:dio/dio.dart';

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
/// Chat images are decoration: none of that is an error worth showing.
Future<Uint8List?> fetchImageBytes(
  Dio dio,
  String url, {
  Map<String, dynamic>? query,
}) async {
  try {
    final r = await dio.get<List<int>>(
      url,
      queryParameters: query,
      options: Options(responseType: ResponseType.bytes),
    );
    final type = r.headers.value(Headers.contentTypeHeader) ?? '';
    final data = r.data;
    if (data == null ||
        data.isEmpty ||
        data.length > maxChatImageBytes ||
        (type.isNotEmpty && !type.startsWith('image/'))) {
      return null;
    }
    return data is Uint8List ? data : Uint8List.fromList(data);
  } catch (_) {
    return null;
  }
}
