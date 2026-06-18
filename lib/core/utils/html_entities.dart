/// Decodes HTML character references from [text].
///
/// Handles numeric decimal (&#39;), numeric hex (&#x27;), and the five
/// predefined named entities (&amp; &lt; &gt; &quot; &apos;).
/// &amp; is decoded last to avoid double-decoding sequences like &amp;lt;.
String decodeHtmlEntities(String text) {
  if (!text.contains('&')) return text;
  var result = text
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m[1]!)),
      )
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);', caseSensitive: false),
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
      )
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
  return result;
}
