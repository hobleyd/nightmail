import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/auth/signed_in_mailbox_lookup.dart';

/// What each provider is asked, and how its answer becomes "the addresses this
/// mailbox receives mail at". The empty list is load-bearing: it is what the
/// guard reads as "could not tell", so a failure here must produce it rather
/// than a partial answer that would be compared as if it were the truth.
void main() {
  final token = AuthToken(
    accessToken: 'under-test',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );

  const jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  /// A Dio answering each path from [bodies] (200), [failing] paths with 403,
  /// and anything else with 404, recording every request in [seen].
  Dio stub(
    Map<String, Object> bodies, {
    Set<String> failing = const {},
    List<RequestOptions>? seen,
  }) {
    final dio = Dio();
    dio.httpClientAdapter = _StubAdapter((options) async {
      seen?.add(options);
      final path = options.uri.path;
      if (failing.contains(path)) {
        return ResponseBody.fromString('{"error":"forbidden"}', 403,
            headers: jsonHeaders);
      }
      final body = bodies[path];
      if (body == null) {
        return ResponseBody.fromString('{}', 404, headers: jsonHeaders);
      }
      return ResponseBody.fromString(jsonEncode(body), 200,
          headers: jsonHeaders);
    });
    return dio;
  }

  group('GmailMailboxLookup', () {
    const profile = '/gmail/v1/users/me/profile';
    const sendAs = '/gmail/v1/users/me/settings/sendAs';

    test('primary address first, then the send-as aliases, no duplicates',
        () async {
      final dio = stub({
        profile: {'emailAddress': 'me@htw.com.au', 'messagesTotal': 1},
        sendAs: {
          'sendAs': [
            {'sendEmail': 'me@htw.com.au', 'isPrimary': true},
            {'sendEmail': 'alias@htw.com.au'},
            {'sendEmail': 'ME@htw.com.au'},
          ],
        },
      });

      expect(
        await GmailMailboxLookup(http: dio).addressesFor(token),
        ['me@htw.com.au', 'alias@htw.com.au'],
      );
    });

    test('sends the token under test as the bearer', () async {
      final seen = <RequestOptions>[];
      final dio = stub({
        profile: {'emailAddress': 'me@htw.com.au'},
      }, seen: seen);

      await GmailMailboxLookup(http: dio).addressesFor(token);

      expect(seen, isNotEmpty);
      for (final request in seen) {
        expect(request.headers['Authorization'], 'Bearer under-test');
      }
    });

    test('a failed profile lookup is "could not tell", whatever sendAs says',
        () async {
      final dio = stub({
        sendAs: {
          'sendAs': [
            {'sendEmail': 'alias@htw.com.au'},
          ],
        },
      }, failing: {profile});

      expect(await GmailMailboxLookup(http: dio).addressesFor(token), isEmpty);
    });

    test('a failed sendAs lookup still answers with the primary', () async {
      final dio = stub({
        profile: {'emailAddress': 'me@htw.com.au'},
      }, failing: {sendAs});

      expect(
        await GmailMailboxLookup(http: dio).addressesFor(token),
        ['me@htw.com.au'],
      );
    });
  });

  group('GraphMailboxLookup', () {
    const me = '/v1.0/me';

    test('mail first, then the UPN, then smtp proxy addresses — nothing else',
        () async {
      final seen = <RequestOptions>[];
      final dio = stub({
        me: {
          'mail': 'me@contoso.com',
          'userPrincipalName': 'me_contoso.com#EXT#@partner.onmicrosoft.com',
          'proxyAddresses': [
            'SMTP:me@contoso.com',
            'smtp:alias@contoso.com',
            'SIP:me@contoso.com',
            'x500:/o=ExchangeLabs/ou=whatever',
          ],
        },
      }, seen: seen);

      expect(
        await GraphMailboxLookup(http: dio).addressesFor(token),
        [
          'me@contoso.com',
          'me_contoso.com#EXT#@partner.onmicrosoft.com',
          'alias@contoso.com',
        ],
      );
      expect(seen.single.headers['Authorization'], 'Bearer under-test');
      expect(seen.single.uri.queryParameters[r'$select'],
          'mail,userPrincipalName,proxyAddresses');
    });

    test('a mailbox with no mail attribute still answers with the UPN',
        () async {
      final dio = stub({
        me: {'mail': null, 'userPrincipalName': 'me@contoso.com'},
      });

      expect(
        await GraphMailboxLookup(http: dio).addressesFor(token),
        ['me@contoso.com'],
      );
    });

    test('a failed lookup is "could not tell"', () async {
      final dio = stub({}, failing: {me});

      expect(await GraphMailboxLookup(http: dio).addressesFor(token), isEmpty);
    });
  });
}

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._respond);

  final Future<ResponseBody> Function(RequestOptions) _respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      _respond(options);

  @override
  void close({bool force = false}) {}
}
