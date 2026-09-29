import '../entities/contact_suggestion.dart';

/// A contact lookup — `SearchContacts` for an account, or the OS address book
/// on its own — that takes the text a user typed and returns ranked matches.
typedef ContactSearch = Future<List<ContactSuggestion>> Function(String query);

/// One pasted line and what the directory made of it.
class RecipientResolution {
  const RecipientResolution({required this.input, this.match});

  /// The line as pasted, trimmed.
  final String input;

  /// The directory entry chosen for [input], or null when the line was
  /// already an address or nothing in the directory fit it.
  final ContactSuggestion? match;

  /// What goes into the recipient list: the directory's `Name <address>`, or
  /// the line untouched when it already carried an address or nothing matched.
  String get recipient => match?.displayText ?? input;

  /// A bare name the directory could not place. Left in the list as typed so
  /// the user can see which ones need fixing rather than silently dropped.
  bool get isUnresolved => match == null && !input.contains('@');
}

/// Turns a pasted list of people — one per line — into recipients.
///
/// A line that already contains `@` is taken as-is (a bare address or a
/// `Name <address>`). Every other line is a display name to look up: a
/// staff list pasted from a spreadsheet, a meeting's attendee names, a list
/// dictated in chat. Lookups run against the same local search as the
/// typeahead, so this never touches the network either.
///
/// Matching a name, in order of preference:
///  1. an entry whose name is the pasted name (ignoring case, punctuation and
///     word order — "Munro, Andrew" is "Andrew Munro");
///  2. an entry each of whose pasted words begins a distinct word of the name,
///     so "Sam Grandidge" finds "Samuel Grandidge";
///  3. the same test over a search for the last word alone, which is what
///     catches "Matt Garrick" when the directory has "Matthew Garrick" — the
///     full-name search cannot, because `LIKE '%matt garrick%'` never matches
///     it.
///
/// Within each step the search's own ranking decides ties, so a colleague on
/// the account's domain wins over an outside contact of the same name.
class ResolveRecipientNames {
  const ResolveRecipientNames();

  /// Splits pasted text into candidate lines: trimmed, blanks dropped.
  static List<String> splitLines(String text) => [
    for (final line in text.split(_lineBreak))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  Future<List<RecipientResolution>> call({
    required List<String> lines,
    required ContactSearch search,
  }) => Future.wait([for (final line in lines) _resolve(line, search)]);

  Future<RecipientResolution> _resolve(
    String line,
    ContactSearch search,
  ) async {
    if (line.contains('@')) return RecipientResolution(input: line);
    final tokens = _tokens(line);
    if (tokens.isEmpty) return RecipientResolution(input: line);

    final byFullName = await search(line);
    for (final s in byFullName) {
      if (_sameTokens(_tokens(s.name ?? ''), tokens)) {
        return RecipientResolution(input: line, match: s);
      }
    }
    for (final s in byFullName) {
      if (_tokensBeginWords(tokens, _tokens(s.name ?? ''))) {
        return RecipientResolution(input: line, match: s);
      }
    }

    if (tokens.length >= 2) {
      final bySurname = await search(tokens.last);
      for (final s in bySurname) {
        if (_tokensBeginWords(tokens, _tokens(s.name ?? ''))) {
          return RecipientResolution(input: line, match: s);
        }
      }
    }
    return RecipientResolution(input: line);
  }

  /// Lower-cased words of a name, split the way `SearchContacts` splits them
  /// so the two agree on what a "word" is, with apostrophes and quotes
  /// removed: "O'Hara" pasted from one source and "O’Hara" stored from
  /// another are the same person.
  static List<String> _tokens(String name) => [
    for (final w
        in name.toLowerCase().replaceAll(_quotes, '').split(_wordBreak))
      if (w.isNotEmpty) w,
  ];

  static bool _sameTokens(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final sortedA = [...a]..sort();
    final sortedB = [...b]..sort();
    for (var i = 0; i < sortedA.length; i++) {
      if (sortedA[i] != sortedB[i]) return false;
    }
    return true;
  }

  /// Every token in [tokens] is a prefix of a different word in [words].
  /// Greedy — longest tokens first, so "sam" cannot steal "samuel" from a
  /// longer token that only fits there.
  static bool _tokensBeginWords(List<String> tokens, List<String> words) {
    if (tokens.isEmpty || tokens.length > words.length) return false;
    final remaining = [...words];
    final ordered = [...tokens]..sort((a, b) => b.length.compareTo(a.length));
    for (final t in ordered) {
      final i = remaining.indexWhere((w) => w.startsWith(t));
      if (i < 0) return false;
      remaining.removeAt(i);
    }
    return true;
  }

  static final _lineBreak = RegExp(r'\r?\n|\r');
  static final _wordBreak = RegExp(r'[\s._\-+,]+');
  static final _quotes = RegExp(r'''[\'"’‘“”]''');
}
