/// The members of `dart:io`'s `Platform` that NightMail uses, answered for a
/// browser: no OS of its own, no environment, `/` paths.
abstract final class Platform {
  static const bool isAndroid = false;
  static const bool isFuchsia = false;
  static const bool isIOS = false;
  static const bool isLinux = false;
  static const bool isMacOS = false;
  static const bool isWindows = false;
  static const String operatingSystem = 'web';
  static const String pathSeparator = '/';
  static const Map<String, String> environment = {};
}
