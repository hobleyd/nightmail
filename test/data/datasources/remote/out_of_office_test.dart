import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/gmail_datasource_impl.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';
import 'package:nightmail/domain/entities/out_of_office_settings.dart';

import 'out_of_office_test.mocks.dart';

/// The two halves of out-of-office support that cannot be seen from the
/// outside: what actually goes on the wire, and how each provider's very
/// different notion of "when" is converted.
///
/// Graph stores a **wall clock plus a zone name** — the mailbox's own, which
/// need not be the device's — so the danger is converting through UTC and
/// moving the date across midnight. Gmail stores **epoch milliseconds**, as a
/// JSON string, so the danger is the end date silently meaning midnight at the
/// *start* of the last day and the user losing it.
@GenerateMocks([Dio])
void main() {
  group('Graph', () {
    late MockDio dio;
    late GraphApiDatasourceImpl datasource;

    /// A mailbox whose own zone is not UTC, which is the case that catches a
    /// conversion. `scheduledEndDateTime` is the last moment of the 27th.
    const settingsResponse = {
      'timeZone': 'AUS Eastern Standard Time',
      'automaticRepliesSetting': {
        'status': 'scheduled',
        'externalAudience': 'contactsOnly',
        'internalReplyMessage': '<div>Away.</div>',
        'externalReplyMessage': '<div>Out of the office.</div>',
        'scheduledStartDateTime': {
          'dateTime': '2026-09-20T00:00:00.0000000',
          'timeZone': 'AUS Eastern Standard Time',
        },
        'scheduledEndDateTime': {
          'dateTime': '2026-09-27T23:59:59.0000000',
          'timeZone': 'AUS Eastern Standard Time',
        },
      },
    };

    Map<String, dynamic> capturedPatchBody() {
      final captured = verify(
        dio.patch<Map<String, dynamic>>('/me/mailboxSettings',
            data: captureAnyNamed('data')),
      ).captured.single as Map<String, dynamic>;
      return captured['automaticRepliesSetting'] as Map<String, dynamic>;
    }

    setUp(() {
      dio = MockDio();
      datasource = GraphApiDatasourceImpl.withDio(dio);
      when(dio.get<Map<String, dynamic>>('/me/mailboxSettings',
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                data: settingsResponse,
                statusCode: 200,
                requestOptions: RequestOptions(path: '/me/mailboxSettings'),
              ));
      when(dio.patch<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenAnswer((_) async => Response(
                data: const {},
                statusCode: 200,
                requestOptions: RequestOptions(path: '/me/mailboxSettings'),
              ));
    });

    test('reads the schedule as a wall clock, with no conversion', () async {
      final settings = await datasource.getOutOfOffice();

      expect(settings.enabled, isTrue);
      // The field values verbatim. Parsing the string as an instant and
      // converting to the device's zone is what would move these.
      expect(settings.start, DateTime(2026, 9, 20));
      expect(settings.end, DateTime(2026, 9, 27, 23, 59, 59));
      expect(settings.messageHtml, '<div>Away.</div>');
    });

    test('reads the audience and opens on the mailbox\'s two messages',
        () async {
      final settings = await datasource.getOutOfOffice();
      expect(settings.audience, OutOfOfficeAudience.contacts);
      // A mailbox that really holds two different texts opens with the
      // separate-message option already on, so what is shown matches what is
      // stored and saving cannot replace one with the other.
      expect(settings.useSeparateExternalMessage, isTrue);
      expect(settings.externalMessageHtml, '<div>Out of the office.</div>');
    });

    test('one message used for both is not a separate message', () {
      final settings = GraphApiDatasourceImpl.parseAutomaticReplies(const {
        'automaticRepliesSetting': {
          'status': 'scheduled',
          'externalAudience': 'all',
          'internalReplyMessage': '<div>Away.</div>',
          'externalReplyMessage': '<div>Away.</div>',
        },
      });
      expect(settings.useSeparateExternalMessage, isFalse);
      expect(settings.audience, OutOfOfficeAudience.everyone);
    });

    test('maps every audience value in both directions', () async {
      OutOfOfficeAudience read(String? raw) =>
          GraphApiDatasourceImpl.parseAutomaticReplies({
            'automaticRepliesSetting': {
              'status': 'scheduled',
              if (raw != null) 'externalAudience': raw,
            },
          }).audience;

      expect(read('all'), OutOfOfficeAudience.everyone);
      expect(read('contactsOnly'), OutOfOfficeAudience.contacts);
      expect(read('none'), OutOfOfficeAudience.organisationOnly);
      // A mailbox that has never had an automatic reply names no audience;
      // `all` is the answer that reaches the people the user is telling.
      expect(read(null), OutOfOfficeAudience.everyone);

      for (final (audience, wire) in [
        (OutOfOfficeAudience.everyone, 'all'),
        (OutOfOfficeAudience.contacts, 'contactsOnly'),
        (OutOfOfficeAudience.organisationOnly, 'none'),
      ]) {
        await datasource.setOutOfOffice(OutOfOfficeSettings(
          enabled: true,
          start: DateTime(2026, 10, 5),
          end: DateTime(2026, 10, 9, 23, 59, 59),
          messageHtml: '<div>Away.</div>',
          audience: audience,
        ));
        expect(capturedPatchBody()['externalAudience'], wire,
            reason: audience.name);
        clearInteractions(dio);
      }
    });

    test('a mailbox with nothing scheduled reports no dates', () {
      final settings = GraphApiDatasourceImpl.parseAutomaticReplies(const {
        'automaticRepliesSetting': {
          'status': 'disabled',
          'externalAudience': 'all',
          // Graph's own "unset" — a null date wearing a costume.
          'scheduledStartDateTime': {
            'dateTime': '0001-01-01T00:00:00.0000000',
            'timeZone': 'UTC',
          },
          'scheduledEndDateTime': {
            'dateTime': '0001-01-01T00:00:00.0000000',
            'timeZone': 'UTC',
          },
        },
      });

      expect(settings.enabled, isFalse);
      expect(settings.start, isNull);
      expect(settings.end, isNull);
      expect(settings.audience, OutOfOfficeAudience.everyone);
    });

    test('writes the bounds in the mailbox timezone, not UTC', () async {
      await datasource.setOutOfOffice(OutOfOfficeSettings(
        enabled: true,
        start: DateTime(2026, 10, 5),
        end: DateTime(2026, 10, 9, 23, 59, 59),
        messageHtml: '<div>Back on the 12th.</div>',
      ));

      final body = capturedPatchBody();
      final start = body['scheduledStartDateTime'] as Map;
      final end = body['scheduledEndDateTime'] as Map;

      // Both halves have to describe the same zone. Local field values
      // labelled 'UTC' is how "away from the 5th" arrives mid-morning.
      expect(start['timeZone'], 'AUS Eastern Standard Time');
      expect(end['timeZone'], 'AUS Eastern Standard Time');
      expect(start['dateTime'], '2026-10-05T00:00:00.0000000');
      expect(end['dateTime'], '2026-10-09T23:59:59.0000000');
      expect(body['status'], 'scheduled');
    });

    test('sends both messages, and the same one twice by default', () async {
      await datasource.setOutOfOffice(OutOfOfficeSettings(
        enabled: true,
        start: DateTime(2026, 10, 5),
        end: DateTime(2026, 10, 9, 23, 59, 59),
        messageHtml: '<div>Away.</div>',
        // Retained but not in use: turning the option off must not leave an
        // old external text behind to be sent to people the screen said would
        // get something else.
        externalMessageHtml: '<div>Something else entirely.</div>',
      ));

      final body = capturedPatchBody();
      expect(body['internalReplyMessage'], '<div>Away.</div>');
      expect(body['externalReplyMessage'], '<div>Away.</div>');
    });

    test('sends the external message when it is in use', () async {
      await datasource.setOutOfOffice(OutOfOfficeSettings(
        enabled: true,
        start: DateTime(2026, 10, 5),
        end: DateTime(2026, 10, 9, 23, 59, 59),
        messageHtml: '<div>Away.</div>',
        useSeparateExternalMessage: true,
        externalMessageHtml: '<div>I am out of the office.</div>',
      ));

      final body = capturedPatchBody();
      expect(body['internalReplyMessage'], '<div>Away.</div>');
      expect(body['externalReplyMessage'], '<div>I am out of the office.</div>');
    });

    test('turning it off still sends the message and the window', () async {
      await datasource.setOutOfOffice(OutOfOfficeSettings(
        enabled: false,
        start: DateTime(2026, 10, 5),
        end: DateTime(2026, 10, 9, 23, 59, 59),
        messageHtml: '<div>Away.</div>',
      ));
      expect(capturedPatchBody()['status'], 'disabled');
    });
  });

  group('Gmail', () {
    late MockDio dio;
    late GmailDatasourceImpl datasource;

    const path = '/users/me/settings/vacation';

    // Google serialises int64 as a JSON *string*. A parser that assumed a
    // number would read every schedule as absent.
    final startMs = DateTime(2026, 9, 20).millisecondsSinceEpoch;
    final endMs = DateTime(2026, 9, 27, 23, 59, 59).millisecondsSinceEpoch;

    late Map<String, dynamic> current;

    Map<String, dynamic> capturedPutBody() => verify(
          dio.put<Map<String, dynamic>>(path, data: captureAnyNamed('data')),
        ).captured.single as Map<String, dynamic>;

    setUp(() {
      dio = MockDio();
      datasource = GmailDatasourceImpl.withDio(dio);
      current = {
        'enableAutoReply': true,
        'responseSubject': 'Out of office',
        'responseBodyHtml': '<div>Away.</div>',
        'responseBodyPlainText': 'Away.',
        'restrictToContacts': true,
        'restrictToDomain': false,
        'startTime': '$startMs',
        'endTime': '$endMs',
      };
      when(dio.get<Map<String, dynamic>>(path)).thenAnswer((_) async => Response(
            data: current,
            statusCode: 200,
            requestOptions: RequestOptions(path: path),
          ));
      when(dio.put<Map<String, dynamic>>(path, data: anyNamed('data')))
          .thenAnswer((_) async => Response(
                data: const {},
                statusCode: 200,
                requestOptions: RequestOptions(path: path),
              ));
    });

    test('reads epoch milliseconds given as strings', () async {
      final settings = await datasource.getOutOfOffice();
      expect(settings.enabled, isTrue);
      expect(settings.start, DateTime(2026, 9, 20));
      expect(settings.end, DateTime(2026, 9, 27, 23, 59, 59));
      expect(settings.audience, OutOfOfficeAudience.contacts);
      // Gmail has one body in two renderings — there is no split to offer.
      expect(settings.useSeparateExternalMessage, isFalse);
    });

    test('a mailbox restricted both ways reads as the narrower of the two', () {
      // Workspace only, and only reachable from Gmail's own UI: the responder
      // answers people who are in the domain *and* in the contacts. It reads
      // back as "organisation only", which stays true of it.
      final settings = GmailDatasourceImpl.parseVacationSettings(const {
        'enableAutoReply': true,
        'restrictToDomain': true,
        'restrictToContacts': true,
      });
      expect(settings.audience, OutOfOfficeAudience.organisationOnly);
    });

    test('writes both flags from the one choice, never merging', () async {
      for (final (audience, domain, contacts) in [
        (OutOfOfficeAudience.everyone, false, false),
        (OutOfOfficeAudience.contacts, false, true),
        (OutOfOfficeAudience.organisationOnly, true, false),
      ]) {
        await datasource.setOutOfOffice(OutOfOfficeSettings(
          enabled: true,
          start: DateTime(2026, 10, 5),
          end: DateTime(2026, 10, 9, 23, 59, 59),
          messageHtml: '<div>Away.</div>',
          audience: audience,
        ));
        final body = capturedPutBody();
        // Leaving the *other* flag where it was would land the user somewhere
        // they never chose, by a rule they cannot see — a labelled option has
        // to mean exactly what it says. Note `current` above has
        // restrictToContacts set, so a merge would show here.
        expect(body['restrictToDomain'], domain, reason: audience.name);
        expect(body['restrictToContacts'], contacts, reason: audience.name);
        clearInteractions(dio);
      }
    });

    test('a zero bound is "no bound", not 1 January 1970', () {
      final settings = GmailDatasourceImpl.parseVacationSettings(const {
        'enableAutoReply': true,
        'startTime': '0',
        'endTime': 0,
      });
      expect(settings.start, isNull);
      expect(settings.end, isNull);
    });

    test('writes the window as epoch milliseconds, end inclusive', () async {
      await datasource.setOutOfOffice(OutOfOfficeSettings(
        enabled: true,
        start: DateTime(2026, 10, 5),
        // The last moment of the last day. Midnight *starting* the end date
        // would switch the responder off a day early.
        end: DateTime(2026, 10, 9, 23, 59, 59),
        messageHtml: '<div>Back on the 12th.</div>',
      ));

      final body = capturedPutBody();
      expect(body['startTime'], '${DateTime(2026, 10, 5).millisecondsSinceEpoch}');
      expect(body['endTime'],
          '${DateTime(2026, 10, 9, 23, 59, 59).millisecondsSinceEpoch}');
      expect(body['enableAutoReply'], isTrue);
      expect(body['responseBodyHtml'], '<div>Back on the 12th.</div>');
      // The plain alternative has to move with the HTML, or Gmail keeps
      // sending the previous message to anything that cannot render HTML.
      expect(body['responseBodyPlainText'], 'Back on the 12th.');
    });

    test('preserves the fields this screen never shows', () async {
      await datasource.setOutOfOffice(OutOfOfficeSettings(
        enabled: true,
        start: DateTime(2026, 10, 5),
        end: DateTime(2026, 10, 9, 23, 59, 59),
        messageHtml: '<div>Away.</div>',
      ));

      // updateVacation is a PUT: an omitted field is a cleared field, so the
      // reply subject — which this screen has no control for — would be wiped
      // by a partial write. The restrict-to flags are *not* in this category
      // any more: they are the audience, and the audience is chosen here.
      expect(capturedPutBody()['responseSubject'], 'Out of office');
    });

    test('a plain-text-only responder still yields something to edit', () {
      final settings = GmailDatasourceImpl.parseVacationSettings(const {
        'enableAutoReply': true,
        'responseBodyPlainText': 'Away.\n\nBack Monday.',
      });
      expect(settings.messageHtml, contains('Away.'));
      expect(settings.messageHtml, contains('Back Monday.'));
    });
  });
}
