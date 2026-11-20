import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/gmail_datasource_impl.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';
import 'package:nightmail/data/datasources/remote/mail_rule_codecs.dart';
import 'package:nightmail/domain/entities/mail_rule.dart';

import 'mail_rules_test.mocks.dart';

/// Server-side mail rules: Graph's inbox `messageRules` (and Nightware's copy
/// of it) and Gmail's filters.
///
/// The traps are all about losing something the screen never showed. Graph
/// replaces `conditions`/`actions` whole on PATCH, so a rule holding a
/// predicate the form cannot draw must open view-only rather than be thinned
/// on save; and Gmail has no filter update, so an edit is a create followed
/// by a delete, in that order.
@GenerateMocks([Dio])
void main() {
  group('Graph codec', () {
    const outlookRule = {
      'id': 'r1',
      'displayName': 'From the boss',
      'sequence': 2,
      'isEnabled': true,
      'hasError': false,
      'isReadOnly': false,
      'conditions': {
        'fromAddresses': [
          {
            'emailAddress': {'name': 'Boss', 'address': 'boss@example.com'},
          },
        ],
        'subjectContains': ['urgent', 'asap'],
        // Unset predicates as some tenants send them: none is a condition.
        'bodyContains': [],
        'hasAttachments': false,
        'importance': null,
      },
      'exceptions': {
        'withinSizeRange': {'minimumSize': 0, 'maximumSize': 2048},
      },
      'actions': {
        'moveToFolder': 'folder-1',
        'markImportance': 'high',
        'stopProcessingRules': true,
        'forwardTo': [
          {
            'emailAddress': {'address': 'pa@example.com'},
          },
        ],
      },
    };

    test('decodes every modelled predicate and action', () {
      final rule = GraphMailRuleCodec.decode(outlookRule);

      expect(rule.id, 'r1');
      expect(rule.name, 'From the boss');
      expect(rule.sequence, 2);
      expect(rule.hasUnsupportedParts, isFalse);
      expect(rule.isEditable, isTrue);
      expect(rule.conditions, [
        const MailRuleCondition(
          MailRuleConditionKind.fromAddresses,
          values: ['boss@example.com'],
        ),
        const MailRuleCondition(
          MailRuleConditionKind.subjectContains,
          values: ['urgent', 'asap'],
        ),
      ]);
      // 0 is Graph's "no bound": only the maximum is a condition.
      expect(rule.exceptions, [
        const MailRuleCondition(
          MailRuleConditionKind.maximumSize,
          sizeKb: 2048,
        ),
      ]);
      expect(
        rule.actions,
        containsAll([
          const MailRuleAction(
            MailRuleActionKind.moveToFolder,
            folderId: 'folder-1',
          ),
          const MailRuleAction(
            MailRuleActionKind.markImportance,
            importance: MailRuleImportance.high,
          ),
          const MailRuleAction(MailRuleActionKind.stopProcessingRules),
          const MailRuleAction(
            MailRuleActionKind.forwardTo,
            addresses: ['pa@example.com'],
          ),
        ]),
      );
    });

    test('round-trips a rule through encode and decode unchanged', () {
      final rule = GraphMailRuleCodec.decode(outlookRule);
      final again = GraphMailRuleCodec.decode({
        'id': 'r1',
        ...GraphMailRuleCodec.encode(rule),
      });

      expect(again.conditions, rule.conditions);
      expect(again.exceptions, rule.exceptions);
      expect(again.actions.toSet(), rule.actions.toSet());
      expect(again.name, rule.name);
    });

    test('a predicate the form cannot draw makes the rule view-only', () {
      // `categories` is a real Graph predicate this screen does not model.
      // Editing it here would PATCH `conditions` without it, and Graph
      // replaces the whole object — the category test would simply vanish.
      final rule = GraphMailRuleCodec.decode({
        'id': 'r2',
        'displayName': 'Tagged',
        'conditions': {
          'categories': ['Red'],
          'subjectContains': ['x'],
        },
        'actions': {'markAsRead': true},
      });

      expect(rule.hasUnsupportedParts, isTrue);
      expect(rule.isEditable, isFalse);
    });

    test('an unmodelled action makes the rule view-only too', () {
      final rule = GraphMailRuleCodec.decode({
        'id': 'r3',
        'conditions': {'hasAttachments': true},
        'actions': {
          'assignCategories': ['Blue'],
        },
      });

      expect(rule.hasUnsupportedParts, isTrue);
    });

    test('always sends exceptions, so removing them clears them', () {
      final body = GraphMailRuleCodec.encode(
        const MailRule(
          name: 'n',
          conditions: [MailRuleCondition(MailRuleConditionKind.hasAttachments)],
          actions: [MailRuleAction(MailRuleActionKind.markAsRead)],
        ),
      );

      // An omitted `exceptions` leaves the old ones in place on PATCH.
      expect(body['exceptions'], <String, dynamic>{});
      expect(body['conditions'], {'hasAttachments': true});
      expect(body['actions'], {'markAsRead': true});
    });

    test('a one-sided size range writes a literally-true open side', () {
      final body = GraphMailRuleCodec.encodePredicates(const [
        MailRuleCondition(MailRuleConditionKind.minimumSize, sizeKb: 500),
      ]);

      // Not 0: whether Graph reads a zero maximum as "unbounded" is not
      // documented, and if it does not, "at least 500 KB" matches nothing.
      expect(body, {
        'withinSizeRange': {'minimumSize': 500, 'maximumSize': 2147483647},
      });
      expect(
        GraphMailRuleCodec.decodePredicates(body).conditions,
        [const MailRuleCondition(MailRuleConditionKind.minimumSize, sizeKb: 500)],
      );
    });
  });

  group('Gmail codec', () {
    test('a label plus skipping the inbox reads as a move', () {
      final rule = GmailFilterCodec.decode({
        'id': 'f1',
        'criteria': {'from': 'news@example.com'},
        'action': {
          'addLabelIds': ['Label_7'],
          'removeLabelIds': ['INBOX', 'UNREAD'],
        },
      });

      expect(rule.hasUnsupportedParts, isFalse);
      expect(rule.conditions, [
        const MailRuleCondition(
          MailRuleConditionKind.senderContains,
          values: ['news@example.com'],
        ),
      ]);
      expect(
        rule.actions,
        containsAll([
          const MailRuleAction(MailRuleActionKind.markAsRead),
          const MailRuleAction(
            MailRuleActionKind.moveToFolder,
            folderId: 'Label_7',
          ),
        ]),
      );
      expect(rule.actions, hasLength(2));
    });

    test('skipping the inbox with no label reads as archive', () {
      final rule = GmailFilterCodec.decode({
        'id': 'f2',
        'criteria': {'query': 'unsubscribe'},
        'action': {
          'removeLabelIds': ['INBOX'],
        },
      });

      expect(rule.actions, [
        const MailRuleAction(MailRuleActionKind.archive),
      ]);
    });

    test('criteria are carried verbatim, so an untouched filter writes back '
        'exactly as stored', () {
      const stored = {
        'id': 'f3',
        'criteria': {
          'from': '(alice@example.com OR bob@example.com)',
          'negatedQuery': 'list:announce',
          'hasAttachment': true,
        },
        'action': {
          'addLabelIds': ['Label_1', 'STARRED', 'IMPORTANT'],
        },
      };
      final rule = GmailFilterCodec.decode(stored);
      final body = GmailFilterCodec.encode(rule);

      expect(body['criteria'], stored['criteria']);
      expect(
        (body['action'] as Map)['addLabelIds'],
        unorderedEquals(['Label_1', 'STARRED', 'IMPORTANT']),
      );
    });

    test('several alternatives are ORed, bracketing multi-word ones', () {
      final body = GmailFilterCodec.encode(
        const MailRule(
          conditions: [
            MailRuleCondition(
              MailRuleConditionKind.subjectContains,
              values: ['weekly report', 'digest'],
            ),
          ],
          actions: [MailRuleAction(MailRuleActionKind.markAsRead)],
        ),
      );

      expect((body['criteria'] as Map)['subject'], '(weekly report) OR digest');
    });

    test('never-important writes IMPORTANT into the removals', () {
      final body = GmailFilterCodec.encode(
        const MailRule(
          conditions: [MailRuleCondition(MailRuleConditionKind.hasAttachments)],
          actions: [
            MailRuleAction(
              MailRuleActionKind.markImportance,
              importance: MailRuleImportance.low,
            ),
            MailRuleAction(MailRuleActionKind.neverSpam),
          ],
        ),
      );

      expect(body['action'], {
        'removeLabelIds': ['IMPORTANT', 'SPAM'],
      });
    });

    test('a forward, a size test or a category is unsupported', () {
      for (final filter in [
        {
          'criteria': {'from': 'a'},
          'action': {'forward': 'b@example.com'},
        },
        {
          'criteria': {'size': 1000000, 'sizeComparison': 'larger'},
          'action': {
            'addLabelIds': ['TRASH'],
          },
        },
        {
          'criteria': {'from': 'a'},
          'action': {
            'addLabelIds': ['CATEGORY_PROMOTIONS'],
          },
        },
      ]) {
        expect(
          GmailFilterCodec.decode(filter).hasUnsupportedParts,
          isTrue,
          reason: '$filter',
        );
      }
    });
  });

  group('Gmail datasource', () {
    late MockDio dio;
    late GmailDatasourceImpl datasource;

    const rule = MailRule(
      id: 'old',
      conditions: [
        MailRuleCondition(
          MailRuleConditionKind.senderContains,
          values: ['x@example.com'],
        ),
      ],
      actions: [MailRuleAction(MailRuleActionKind.archive)],
    );

    Response<T> ok<T>(T data) => Response<T>(
      data: data,
      statusCode: 200,
      requestOptions: RequestOptions(path: '/users/me/settings/filters'),
    );

    DioException duplicate() {
      final options = RequestOptions(path: '/users/me/settings/filters');
      return DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: options,
          statusCode: 400,
          data: {
            'error': {'code': 400, 'message': 'Filter already exists'},
          },
        ),
      );
    }

    setUp(() {
      dio = MockDio();
      datasource = GmailDatasourceImpl.withDio(dio);
      when(dio.delete<void>(any)).thenAnswer((_) async => ok<void>(null));
    });

    test('an edit creates the new filter before deleting the old one', () async {
      when(dio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenAnswer((_) async => ok(<String, dynamic>{'id': 'new'}));

      await datasource.updateMailRule(rule);

      // The order is the point: a failed create must leave the original.
      verifyInOrder([
        dio.post<Map<String, dynamic>>(
          '/users/me/settings/filters',
          data: anyNamed('data'),
        ),
        dio.delete<void>('/users/me/settings/filters/old'),
      ]);
    });

    test('a failed create leaves the old filter alone', () async {
      when(dio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenThrow(
            DioException(
              requestOptions: RequestOptions(path: '/x'),
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: RequestOptions(path: '/x'),
                statusCode: 500,
              ),
            ),
          );

      await expectLater(
        datasource.updateMailRule(rule),
        throwsA(isA<ServerException>()),
      );
      verifyNever(dio.delete<void>(any));
    });

    test('an edit back onto the stored settings changes nothing', () async {
      // The old filter is still there when the new one is created, so
      // landing back on its exact settings collides with it.
      when(dio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenThrow(duplicate());

      await datasource.updateMailRule(rule);

      verifyNever(dio.delete<void>(any));
    });

    test('a new filter that duplicates one says so', () async {
      when(dio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenThrow(duplicate());

      await expectLater(
        datasource.createMailRule(rule),
        throwsA(
          isA<ServerException>().having(
            (e) => e.message,
            'message',
            contains('already exists'),
          ),
        ),
      );
    });

    test('a mailbox with no filters answers {} and reads as none', () async {
      when(dio.get<Map<String, dynamic>>('/users/me/settings/filters'))
          .thenAnswer((_) async => ok(<String, dynamic>{}));

      expect(await datasource.getMailRules(), isEmpty);
    });
  });

  group('Graph datasource', () {
    late MockDio dio;
    late GraphApiDatasourceImpl datasource;

    setUp(() {
      dio = MockDio();
      datasource = GraphApiDatasourceImpl.withDio(dio);
      when(dio.patch<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenAnswer(
            (_) async => Response(
              data: const <String, dynamic>{},
              statusCode: 200,
              requestOptions: RequestOptions(path: '/x'),
            ),
          );
    });

    test('switching a rule off sends only isEnabled', () async {
      // Never the whole rule: this is what keeps a view-only rule (one with
      // predicates the form cannot draw) switchable without loss.
      await datasource.setMailRuleEnabled('r1', false);

      verify(
        dio.patch<Map<String, dynamic>>(
          '/me/mailFolders/inbox/messageRules/r1',
          data: {'isEnabled': false},
        ),
      ).called(1);
    });

    test('reordering PATCHes only the sequences of the rules named', () async {
      await datasource.reorderMailRules({'b': 3, 'a': 7});

      verify(
        dio.patch<Map<String, dynamic>>(
          '/me/mailFolders/inbox/messageRules/b',
          data: {'sequence': 3},
        ),
      ).called(1);
      verify(
        dio.patch<Map<String, dynamic>>(
          '/me/mailFolders/inbox/messageRules/a',
          data: {'sequence': 7},
        ),
      ).called(1);
      verifyNoMoreInteractions(dio);
    });

    test('lists every rule, decoded and in run order', () async {
      when(
        dio.get<String>(
          '/me/mailFolders/inbox/messageRules',
          queryParameters: anyNamed('queryParameters'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response(
          data: '{"value":['
              '{"id":"late","displayName":"Late","sequence":9,'
              '"conditions":{"hasAttachments":true},'
              '"actions":{"markAsRead":true}},'
              '{"id":"early","displayName":"Early","sequence":1,'
              '"conditions":{"subjectContains":["x"]},'
              '"actions":{"delete":true}}]}',
          statusCode: 200,
          requestOptions: RequestOptions(path: '/x'),
        ),
      );

      final rules = await datasource.getMailRules();

      expect(rules.map((r) => r.id), ['early', 'late']);
      expect(rules.first.actions, [
        const MailRuleAction(MailRuleActionKind.delete),
      ]);
    });
  });
}
