import 'dart:convert';

/// Turns an HTML signature file (a signature-generator export, or the `.htm`
/// Outlook keeps under its Signatures folder) into the signature template
/// stored on the account. Merge tags and `IFEXISTS(...)` calls are left as
/// they are — `SignatureMergeEngine` resolves them at compose time, the same
/// as for a signature typed into the editor.
///
/// This only decodes the file and slices out the `<body>`; sanitising happens
/// where every inbound HTML does, in the editor's `setContent`.
class SignatureImport {
  SignatureImport._();

  static String fromBytes(List<int> bytes) {
    final body = _extractBody(_decode(bytes));
    return body.trim();
  }

  /// UTF-8 or UTF-16 when the file says so with a BOM, UTF-8 when it decodes
  /// as such, otherwise Windows-1252 — what Outlook writes its `.htm`
  /// signatures in, and where smart quotes and dashes would otherwise come out
  /// as Latin-1 control characters.
  static String _decode(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return String.fromCharCodes(bytes.map(_cp1252));
    }
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  // Windows-1252 differs from Latin-1 only in 0x80–0x9F.
  static const _cp1252High = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
  ];

  static int _cp1252(int b) =>
      b >= 0x80 && b <= 0x9F ? _cp1252High[b - 0x80] : b;

  static String _extractBody(String html) {
    final open = RegExp(r'<body[^>]*>', caseSensitive: false).firstMatch(html);
    if (open == null) return html;
    final close = RegExp(r'</body>', caseSensitive: false)
        .allMatches(html)
        .where((m) => m.start >= open.end)
        .lastOrNull;
    return html.substring(open.end, close?.start ?? html.length);
  }
}
