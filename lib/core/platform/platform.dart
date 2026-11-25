/// `Platform` for code that also runs on the web. `dart:io`'s compiles there
/// but throws on every member, so files that ask which OS they are on import
/// this instead (`import 'dart:io' hide Platform;`). On the web every `isX`
/// is false.
export 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';
