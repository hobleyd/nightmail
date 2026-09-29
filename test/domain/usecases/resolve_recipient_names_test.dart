import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/usecases/resolve_recipient_names.dart';

/// A stand-in for `SearchContacts`: substring match on the name, already
/// ordered the way the real search would rank it (the list order).
ContactSearch _searchOver(List<ContactSuggestion> directory) =>
    (String query) async {
      final q = query.toLowerCase();
      return [
        for (final s in directory)
          if ((s.name ?? '').toLowerCase().contains(q) ||
              s.address.toLowerCase().contains(q))
            s,
      ];
    };

void main() {
  const useCase = ResolveRecipientNames();

  const directory = [
    ContactSuggestion(address: 'andrew.munro@htw.com.au', name: 'Andrew Munro'),
    ContactSuggestion(
      address: 'matthew.garrick@htw.com.au',
      name: 'Matthew Garrick',
    ),
    ContactSuggestion(
      address: 'samuel.grandidge@htw.com.au',
      name: 'Samuel Grandidge',
    ),
    ContactSuggestion(
      address: 'michael.ohs@htw.com.au',
      name: "Michael O’Hara-Sanderson",
    ),
    ContactSuggestion(address: 'pam.kingston@htw.com.au', name: 'Pam Kingston'),
    ContactSuggestion(address: 'pam.king@htw.com.au', name: 'Pam King'),
    ContactSuggestion(
      address: 'gerard.s@htw.com.au',
      name: 'Santamaria, Gerard',
    ),
    ContactSuggestion(address: 'matt.slack@example.com', name: 'Matt Slack'),
    ContactSuggestion(address: 'noname@htw.com.au'),
  ];

  group('ResolveRecipientNames.splitLines', () {
    test('splits on any line ending, trims, drops blanks', () {
      expect(ResolveRecipientNames.splitLines('  a \r\nb\n\n c\rd\n'), [
        'a',
        'b',
        'c',
        'd',
      ]);
    });
  });

  group('ResolveRecipientNames', () {
    Future<List<RecipientResolution>> resolve(List<String> lines) =>
        useCase(lines: lines, search: _searchOver(directory));

    test('an exact name becomes the directory entry, in input order', () async {
      final r = await resolve(['Andrew Munro', 'Matt Slack']);
      expect(r.map((x) => x.recipient), [
        'Andrew Munro <andrew.munro@htw.com.au>',
        'Matt Slack <matt.slack@example.com>',
      ]);
      expect(r.every((x) => !x.isUnresolved), isTrue);
    });

    test('ignores case, quotes and word order', () async {
      final r = await resolve([
        'andrew MUNRO',
        "Michael O'Hara-Sanderson",
        'Gerard santamaria',
      ]);
      expect(r.map((x) => x.match?.address), [
        'andrew.munro@htw.com.au',
        'michael.ohs@htw.com.au',
        'gerard.s@htw.com.au',
      ]);
    });

    test('a shortened first name is found via the surname search', () async {
      final r = await resolve(['Matt Garrick', 'Sam Grandidge']);
      expect(r.map((x) => x.match?.address), [
        'matthew.garrick@htw.com.au',
        'samuel.grandidge@htw.com.au',
      ]);
    });

    test('an exact name beats a longer name it merely prefixes', () async {
      // The search returns Kingston first; exact wins regardless.
      final r = await resolve(['Pam King']);
      expect(r.single.match?.address, 'pam.king@htw.com.au');
    });

    test('a line with an address is passed through untouched', () async {
      final r = await resolve([
        'someone@example.com',
        'Named Person <named@example.com>',
      ]);
      expect(r.map((x) => x.recipient), [
        'someone@example.com',
        'Named Person <named@example.com>',
      ]);
      expect(r.every((x) => !x.isUnresolved), isTrue);
    });

    test('an unknown name is kept as typed and flagged', () async {
      final r = await resolve(['Nobody Here']);
      expect(r.single.recipient, 'Nobody Here');
      expect(r.single.isUnresolved, isTrue);
    });

    test('a shared surname alone is not a match', () async {
      // The surname search for "King" returns both Pams; neither begins with
      // "Peter", so nothing is taken rather than the wrong person.
      final r = await resolve(['Peter King']);
      expect(r.single.isUnresolved, isTrue);
    });

    test('never matches a bare address on a name lookup', () async {
      final r = await resolve(['noname']);
      expect(r.single.isUnresolved, isTrue);
    });
  });
}
