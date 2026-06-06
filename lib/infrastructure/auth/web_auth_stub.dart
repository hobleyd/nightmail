// Stub used on non-web platforms. The conditional import in
// microsoft_auth_service.dart replaces this with web_auth_web.dart on web.
Future<String> authenticateWeb(String url) =>
    throw UnsupportedError('authenticateWeb is only available on web');
