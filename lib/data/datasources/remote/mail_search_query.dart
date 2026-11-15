/// One piece of a search-bar query: either `field:value` for one of
/// [MailSearchQuery.fields], or free text ([field] null) that each provider
/// matches against the whole message — headers *and* body.
class MailSearchTerm {
  const MailSearchTerm({this.field, required this.value, required this.raw});

  /// `from`, `to`, `cc`, `subject` or `body`; null for free text.
  final String? field;

  /// The text to match, with any surrounding quotes removed. A quoted value is
  /// one phrase, never split into words.
  final String value;

  /// The token exactly as typed, quotes included — what a provider with a
  /// richer native syntax than ours passes through untouched.
  final String raw;
}

/// The search bar's query, split into the operators NightMail translates for
/// every provider: `from:`, `to:`, `cc:`, `subject:`, `body:`, `has:attachment`,
/// and free text. Values may be quoted (`subject:"quarterly report"`).
///
/// Anything else that looks like an operator (`after:`, `is:unread`, a time as
/// `10:30`, a URL) stays free text here, so Gmail and Graph can still read
/// their own operators from [MailSearchTerm.raw] while IMAP just searches for
/// the text.
class MailSearchQuery {
  const MailSearchQuery._(this.terms, this.hasAttachment);

  factory MailSearchQuery.parse(String input) {
    final terms = <MailSearchTerm>[];
    var hasAttachment = false;
    for (final m in _tokenRe.allMatches(input)) {
      final raw = m.group(0)!;
      final field = m.group(1)?.toLowerCase();
      final value = m.group(2) ?? m.group(3)!;
      if (field == 'has') {
        if (value.toLowerCase() == 'attachment') {
          hasAttachment = true;
        } else {
          terms.add(MailSearchTerm(value: raw, raw: raw));
        }
        continue;
      }
      if (value.isEmpty) continue;
      terms.add(MailSearchTerm(field: field, value: value, raw: raw));
    }
    return MailSearchQuery._(terms, hasAttachment);
  }

  static const fields = {'from', 'to', 'cc', 'subject', 'body'};

  /// An optional known field, then a quoted phrase or a bare word. An
  /// unterminated quote falls through to the bare-word branch, and a field
  /// with nothing after it (`from: `) backtracks to plain text.
  static final _tokenRe = RegExp(
    r'(?:\b(from|to|cc|subject|body|has):)?(?:"([^"]*)"|(\S+))',
    caseSensitive: false,
  );

  final List<MailSearchTerm> terms;
  final bool hasAttachment;
}

/// The `$search` value for Graph's `/messages`: KQL, which already knows
/// `from:`, `to:`, `subject:` and `body:`, and matches free text against from,
/// subject and body. Only `has:attachment` needs translating. The whole
/// expression goes inside one pair of double quotes, so a quoted phrase's own
/// quotes (and any backslash) are escaped with a backslash.
String graphSearchExpression(String input) {
  final query = MailSearchQuery.parse(input);
  final kql = [
    for (final t in query.terms) t.raw,
    if (query.hasAttachment) 'hasAttachments:true',
  ].join(' ');
  final escaped = kql.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

/// Gmail's `q`: its native syntax already covers everything except `body:`,
/// which Gmail doesn't have — a bare term there searches the body anyway.
String gmailSearchQuery(String input) {
  final query = MailSearchQuery.parse(input);
  return [
    for (final t in query.terms)
      if (t.field == 'body') t.raw.substring('body:'.length) else t.raw,
    if (query.hasAttachment) 'has:attachment',
  ].join(' ');
}

/// IMAP `SEARCH` criteria (RFC 3501 §6.4.4), all ANDed. Free text becomes
/// `TEXT`, which matches the headers and the body; each word is its own
/// criterion, as on Gmail and Graph, while a quoted phrase stays whole.
/// `has:attachment` has no IMAP equivalent and is dropped, as is any other
/// provider operator (`is:unread`, `after:2026/01/01` — the AI agent's
/// search tool may send these): searched for literally it would match nothing.
/// A time or a URL is still searched for.
String imapSearchCriteria(String input) {
  final query = MailSearchQuery.parse(input);
  final terms = [
    for (final t in query.terms)
      if (t.field != null || !_foreignOperatorRe.hasMatch(t.value)) t,
  ];
  if (terms.isEmpty) return 'ALL';

  String quote(String v) =>
      '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  final criteria = [
    for (final t in terms)
      '${(t.field ?? 'text').toUpperCase()} ${quote(t.value)}',
  ].join(' ');
  // Without a charset the server assumes US-ASCII and may reject the command
  // (BADCHARSET) or match nothing for an accented word.
  final ascii = terms.every((t) => t.value.codeUnits.every((c) => c < 128));
  return ascii ? criteria : 'CHARSET UTF-8 $criteria';
}

/// `word:value` where the word is letters only and the value isn't a URL's
/// `//` — so `10:30` and `https://…` don't count.
final _foreignOperatorRe = RegExp(r'^[a-z]+:(?!//)\S', caseSensitive: false);
