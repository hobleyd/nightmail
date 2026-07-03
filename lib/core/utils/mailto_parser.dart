class MailtoData {
  const MailtoData({
    this.to = const [],
    this.cc = const [],
    this.subject = '',
    this.body = '',
  });

  final List<String> to;
  final List<String> cc;
  final String subject;
  final String body;
}

class MailtoParser {
  // RFC 6068: mailto:addr1,addr2?cc=addr3&subject=foo&body=bar
  // '+' is a literal plus in mailto, not a space — use decodeComponent, not
  // decodeQueryComponent, to avoid silently corrupting addresses.
  static MailtoData parse(Uri uri) {
    final pathAddresses = _splitAddresses(uri.path);

    final query = uri.query;
    final params = <String, List<String>>{};
    if (query.isNotEmpty) {
      for (final pair in query.split('&')) {
        final eq = pair.indexOf('=');
        if (eq < 0) continue;
        final key = Uri.decodeComponent(pair.substring(0, eq)).toLowerCase();
        final value = Uri.decodeComponent(pair.substring(eq + 1));
        params.putIfAbsent(key, () => []).add(value);
      }
    }

    final toParam = params['to']?.expand(_splitAddresses).toList() ?? [];
    final ccParam = params['cc']?.expand(_splitAddresses).toList() ?? [];

    return MailtoData(
      to: [...pathAddresses, ...toParam],
      cc: ccParam,
      subject: params['subject']?.firstOrNull ?? '',
      body: params['body']?.firstOrNull ?? '',
    );
  }

  static List<String> _splitAddresses(String s) =>
      s.split(',').map((a) => a.trim()).where((a) => a.isNotEmpty).toList();
}
