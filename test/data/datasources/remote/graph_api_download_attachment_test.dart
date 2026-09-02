import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';

import 'graph_api_download_attachment_test.mocks.dart';

/// Mockito matches on method name and arguments, never on the type argument —
/// a Dart `Invocation` does not carry one — so `get<Map>` and `get<List<int>>`
/// would collide on `any` and the last stub registered would answer both. The
/// two routes are told apart by path instead.
const _attachmentPath = '/me/messages/msg-1/attachments/att-1';
const _valuePath = '/me/messages/msg-1/attachments/att-1/\$value';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GraphApiDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GraphApiDatasourceImpl.withDio(mockDio);
  });

  void stubAttachment(Map<String, dynamic>? data) {
    when(mockDio.get<Map<String, dynamic>>(_attachmentPath))
        .thenAnswer((_) async => Response(
              data: data,
              statusCode: 200,
              requestOptions: RequestOptions(path: _attachmentPath),
            ));
  }

  void stubValue(List<int>? bytes) {
    when(mockDio.get<List<int>>(_valuePath, options: anyNamed('options')))
        .thenAnswer((_) async => Response(
              data: bytes,
              statusCode: 200,
              requestOptions: RequestOptions(path: _valuePath),
            ));
  }

  group('GraphApiDatasourceImpl.downloadAttachment', () {
    test('decodes contentBytes for an ordinary file attachment', () async {
      stubAttachment({'contentBytes': base64Encode(const [1, 2, 3])});

      final bytes = await datasource.downloadAttachment('msg-1', 'att-1');

      expect(bytes, [1, 2, 3]);
      verifyNever(
          mockDio.get<List<int>>(_valuePath, options: anyNamed('options')));
    });

    // An attached email is an itemAttachment, which carries no `contentBytes`
    // at all. This used to throw, so attaching a message in Outlook produced a
    // chip that could not be opened, saved or previewed.
    test('falls back to \$value when contentBytes is absent', () async {
      stubAttachment({'@odata.type': '#microsoft.graph.itemAttachment'});
      stubValue(utf8.encode('From: a@b.com\r\n\r\nBody'));

      final bytes = await datasource.downloadAttachment('msg-1', 'att-1');

      expect(utf8.decode(bytes), startsWith('From: a@b.com'));
    });

    test('falls back to \$value when contentBytes is empty', () async {
      stubAttachment({'contentBytes': ''});
      stubValue(const [9, 9, 9]);

      expect(await datasource.downloadAttachment('msg-1', 'att-1'), [9, 9, 9]);
    });

    test('still fails when neither route serves content', () async {
      stubAttachment({'@odata.type': '#microsoft.graph.itemAttachment'});
      stubValue(const []);

      expect(
        () => datasource.downloadAttachment('msg-1', 'att-1'),
        throwsA(isA<ServerException>()),
      );
    });
  });
}
