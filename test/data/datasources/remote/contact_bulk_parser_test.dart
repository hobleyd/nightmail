// Pure-function tests for the isolate-side address-book parsing. No
// collaborators to mock — the units under test take raw response bodies and
// return normalised contacts.

import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/contact_bulk_parser.dart';
import 'package:nightmail/data/datasources/remote/graph_message_parser.dart'
    show graphDeltaLink;
import 'package:nightmail/domain/entities/cached_contact.dart';

String _googlePage(
  String listKey,
  List<Map<String, dynamic>> persons, {
  String? nextPageToken,
}) =>
    jsonEncode({
      listKey: persons,
      if (nextPageToken != null) 'nextPageToken': nextPageToken,
    });

Map<String, dynamic> _person(String name, List<String> emails) => {
      if (name.isNotEmpty)
        'names': [
          {'displayName': name}
        ],
      'emailAddresses': [
        for (final e in emails) {'value': e},
      ],
    };

CachedContact _find(List<CachedContact> list, String address) =>
    list.firstWhere((c) => c.address == address);

void main() {
  group('parseGooglePeoplePages', () {
    test('reads all three collections and tags each with its source', () {
      final result = parseGooglePeoplePages(GooglePeoplePages(
        connections: [
          _googlePage('connections', [
            _person('Alice Personal', ['alice@corp.com'])
          ])
        ],
        directory: [
          _googlePage('people', [
            _person('Bob Directory', ['bob@corp.com'])
          ])
        ],
        otherContacts: [
          _googlePage('otherContacts', [
            _person('Carol Other', ['carol@corp.com'])
          ])
        ],
      ));

      expect(result.length, 3);
      expect(_find(result, 'alice@corp.com').source, ContactSource.personal);
      expect(_find(result, 'bob@corp.com').source, ContactSource.directory);
      expect(_find(result, 'carol@corp.com').source, ContactSource.other);
    });

    test('keeps the better-ranked source when an address appears twice', () {
      // The same person in the directory and in the user's own contacts.
      final result = parseGooglePeoplePages(GooglePeoplePages(
        connections: [
          _googlePage('connections', [
            _person('Alice', ['alice@corp.com'])
          ])
        ],
        directory: [
          _googlePage('people', [
            _person('Alice Anderson', ['alice@corp.com'])
          ])
        ],
        otherContacts: const [],
      ));

      expect(result.length, 1);
      // The source of the better-ranked copy is kept — personal outranks
      // directory — while the richer of the two names is taken regardless of
      // which source supplied it.
      expect(result.single.source, ContactSource.personal);
      expect(result.single.name, 'Alice Anderson');
    });

    test('takes a name from a lesser source when the better one has none', () {
      final result = parseGooglePeoplePages(GooglePeoplePages(
        connections: [
          _googlePage('connections', [
            _person('', ['alice@corp.com'])
          ])
        ],
        directory: [
          _googlePage('people', [
            _person('Alice Anderson', ['alice@corp.com'])
          ])
        ],
        otherContacts: const [],
      ));

      expect(result.single.name, 'Alice Anderson');
    });

    test('lower-cases addresses and emits one entry per address', () {
      final result = parseGooglePeoplePages(GooglePeoplePages(
        connections: [
          _googlePage('connections', [
            _person('Alice', ['Alice@Corp.com', 'a.anderson@corp.com'])
          ])
        ],
        directory: const [],
        otherContacts: const [],
      ));

      expect(
        result.map((c) => c.address).toSet(),
        {'alice@corp.com', 'a.anderson@corp.com'},
      );
    });

    test('drops entries whose address is not routable', () {
      final result = parseGooglePeoplePages(GooglePeoplePages(
        connections: [
          _googlePage('connections', [
            // Entra/Google service entries frequently look like these.
            _person('No at sign', ['not-an-address']),
            _person('Nothing before', ['@corp.com']),
            _person('Nothing after', ['user@']),
            _person('Fine', ['ok@corp.com']),
          ])
        ],
        directory: const [],
        otherContacts: const [],
      ));

      expect(result.map((c) => c.address), ['ok@corp.com']);
    });

    test('a malformed page loses only that page', () {
      final result = parseGooglePeoplePages(GooglePeoplePages(
        connections: [
          '<html>gateway timeout</html>',
          _googlePage('connections', [
            _person('Alice', ['alice@corp.com'])
          ]),
        ],
        directory: const [],
        otherContacts: const [],
      ));

      expect(result.single.address, 'alice@corp.com');
    });

    test('handles an empty collection response', () {
      final result = parseGooglePeoplePages(const GooglePeoplePages(
        connections: ['{}'],
        directory: [],
        otherContacts: [],
      ));

      expect(result, isEmpty);
    });
  });

  group('parseGraphContactPages', () {
    test('reads Outlook contacts, the directory and /me/people', () {
      final result = parseGraphContactPages(GraphContactPages(
        personalContacts: [
          jsonEncode({
            'value': [
              {
                'displayName': 'Alice Contact',
                'emailAddresses': [
                  {'address': 'alice@corp.com', 'name': 'Alice A'}
                ],
              }
            ]
          })
        ],
        directoryUsers: [
          jsonEncode({
            'value': [
              {
                'displayName': 'Bob User',
                'mail': 'bob@corp.com',
                'userPrincipalName': 'bob_corp@tenant.onmicrosoft.com',
              }
            ]
          })
        ],
        people: [
          jsonEncode({
            'value': [
              {
                'displayName': 'Carol Person',
                'scoredEmailAddresses': [
                  {'address': 'carol@corp.com'}
                ],
              }
            ]
          })
        ],
      ));

      expect(result.length, 3);
      // The per-address name on an Outlook contact wins over displayName.
      expect(_find(result, 'alice@corp.com').name, 'Alice A');
      expect(_find(result, 'alice@corp.com').source, ContactSource.personal);
      // mail wins over userPrincipalName when both are present.
      expect(_find(result, 'bob@corp.com').source, ContactSource.directory);
      expect(_find(result, 'carol@corp.com').source, ContactSource.other);
    });

    test('falls back to userPrincipalName when a user has no mail', () {
      final result = parseGraphContactPages(GraphContactPages(
        personalContacts: const [],
        directoryUsers: [
          jsonEncode({
            'value': [
              {
                'displayName': 'Dana',
                'userPrincipalName': 'dana@corp.com',
              }
            ]
          })
        ],
        people: const [],
      ));

      expect(result.single.address, 'dana@corp.com');
    });

    test('falls back to the contact displayName when an address has no name',
        () {
      final result = parseGraphContactPages(GraphContactPages(
        personalContacts: [
          jsonEncode({
            'value': [
              {
                'displayName': 'Erin Contact',
                'emailAddresses': [
                  {'address': 'erin@corp.com'}
                ],
              }
            ]
          })
        ],
        directoryUsers: const [],
        people: const [],
      ));

      expect(result.single.name, 'Erin Contact');
    });

    test('ignores a response with no value array', () {
      final result = parseGraphContactPages(const GraphContactPages(
        personalContacts: ['{"error":{"code":"Forbidden"}}'],
        directoryUsers: [],
        people: [],
      ));

      expect(result, isEmpty);
    });
  });

  group('parseSystemContacts', () {
    test('normalises channel maps and drops nameless duplicates', () {
      final result = parseSystemContacts([
        {'address': 'Alice@Corp.com', 'name': 'Alice'},
        {'address': 'alice@corp.com', 'name': ''},
        {'address': 'bogus', 'name': 'Bogus'},
      ]);

      expect(result.length, 1);
      expect(result.single.address, 'alice@corp.com');
      expect(result.single.name, 'Alice');
      expect(result.single.source, ContactSource.system);
    });
  });

  group('mergeContacts', () {
    test('prefers the longer name within the same source', () {
      final result = mergeContacts(const [
        CachedContact(
          address: 'a@corp.com',
          name: 'D Hobley',
          source: ContactSource.directory,
        ),
        CachedContact(
          address: 'a@corp.com',
          name: 'David Hobley',
          source: ContactSource.directory,
        ),
      ]);

      expect(result.single.name, 'David Hobley');
    });

    test('does not let a longer name from a worse source change the source',
        () {
      final result = mergeContacts(const [
        CachedContact(
          address: 'a@corp.com',
          name: 'Dave',
          source: ContactSource.sender,
        ),
        CachedContact(
          address: 'a@corp.com',
          name: 'David Hobley',
          source: ContactSource.other,
        ),
      ]);

      expect(result.single.source, ContactSource.sender);
      expect(result.single.name, 'David Hobley');
    });
  });

  group('pagination tokens', () {
    test('googleNextPageToken finds the token and returns null on the last page',
        () {
      final withToken = _googlePage(
        'connections',
        [
          _person('Alice', ['alice@corp.com'])
        ],
        nextPageToken: 'CAESBk5leHRQYWdl',
      );

      expect(googleNextPageToken(withToken), 'CAESBk5leHRQYWdl');
      expect(googleNextPageToken('{"connections":[]}'), isNull);
    });

    test('graphNextLink unescapes the URL it extracts', () {
      // As Graph emits it: escaped slashes and an escaped ampersand.
      const body = r'{"value":[],'
          r'"@odata.nextLink":"https:\/\/graph.microsoft.com\/v1.0\/users'
          r'?$select=displayName\u0026$skiptoken=XYZ"}';

      expect(
        graphNextLink(body),
        'https://graph.microsoft.com/v1.0/users'
        r'?$select=displayName&$skiptoken=XYZ',
      );
    });

    test('graphNextLink returns null on the last page', () {
      expect(graphNextLink('{"value":[]}'), isNull);
    });

    // These links are followed with the account's access token attached, so the
    // host is verified rather than assumed. A link that fails the check reads as
    // no link at all, which ends the paging loop (and, on the delta path, sends
    // the poller down its clear-the-token-and-re-bootstrap route) instead of
    // issuing an authenticated request somewhere unintended.
    test('graphNextLink rejects a link that is not on Graph\'s host', () {
      const body = r'{"value":[],'
          r'"@odata.nextLink":"https:\/\/evil.example\/v1.0\/users"}';
      expect(graphNextLink(body), isNull);
    });

    test('isGraphUrl accepts Graph hosts and rejects everything else', () {
      expect(isGraphUrl('https://graph.microsoft.com/v1.0/me'), isTrue);
      // Sovereign and national clouds are subdomains of the same host.
      expect(isGraphUrl('https://canary.graph.microsoft.com/v1.0/me'), isTrue);

      expect(isGraphUrl('http://graph.microsoft.com/v1.0/me'), isFalse,
          reason: 'a token must never travel over plain http');
      expect(isGraphUrl('https://evil.example/v1.0/me'), isFalse);
      // The classic near-miss: Graph's host as a prefix of someone else's.
      expect(isGraphUrl('https://graph.microsoft.com.evil.example/x'), isFalse);
      expect(isGraphUrl('/v1.0/me'), isFalse, reason: 'not absolute');
      expect(isGraphUrl('not a url at all'), isFalse);
    });

    // The pattern is unanchored and `bodyPreview` is in the delta projection, so
    // it is worth pinning down that a sender cannot smuggle a link in: the
    // pattern needs unescaped quotes around the key, and a quote inside a JSON
    // string value is always escaped.
    test('a delta link in a message body cannot displace the real one', () {
      final page = jsonEncode({
        'value': [
          {
            'id': '1',
            'bodyPreview': '"@odata.deltaLink":"https://evil.example/x"',
          },
        ],
        '@odata.deltaLink':
            'https://graph.microsoft.com/v1.0/me/messages/delta?token=REAL',
      });

      expect(
        graphDeltaLink(page),
        'https://graph.microsoft.com/v1.0/me/messages/delta?token=REAL',
      );
    });
  });

  group('isolate transfer', () {
    // The whole point of this file is that the sync service runs these under
    // compute(). That only works if the argument and return types survive
    // isolate message passing, which a direct call would never exercise.
    test('parseGooglePeoplePages round-trips through compute', () async {
      final result = await compute(
        parseGooglePeoplePages,
        GooglePeoplePages(
          connections: [
            _googlePage('connections', [
              _person('Alice Anderson', ['alice@corp.com'])
            ])
          ],
          directory: const [],
          otherContacts: const [],
        ),
      );

      expect(result.single.address, 'alice@corp.com');
      expect(result.single.name, 'Alice Anderson');
      expect(result.single.source, ContactSource.personal);
    });

    test('parseGraphContactPages round-trips through compute', () async {
      final result = await compute(
        parseGraphContactPages,
        GraphContactPages(
          personalContacts: const [],
          directoryUsers: [
            jsonEncode({
              'value': [
                {'displayName': 'Bob User', 'mail': 'bob@corp.com'}
              ]
            })
          ],
          people: const [],
        ),
      );

      expect(result.single.address, 'bob@corp.com');
      expect(result.single.source, ContactSource.directory);
    });

    test('parseSystemContacts round-trips through compute', () async {
      final result = await compute(parseSystemContacts, [
        {'address': 'alice@corp.com', 'name': 'Alice'},
      ]);

      expect(result.single.source, ContactSource.system);
    });
  });

  group('BulkFetchResult', () {
    test('is complete only with no failures and no truncation', () {
      const complete = BulkFetchResult<int>(data: 1);
      expect(complete.isComplete, isTrue);
      expect(complete.detail, isNull);

      const failed = BulkFetchResult<int>(
        data: 1,
        failures: ['directory: HTTP 403'],
      );
      expect(failed.isComplete, isFalse);
      expect(failed.detail, 'directory: HTTP 403');

      const truncatedResult = BulkFetchResult<int>(data: 1, truncated: true);
      expect(truncatedResult.isComplete, isFalse);
      expect(truncatedResult.detail, contains('page cap'));
    });
  });
}
