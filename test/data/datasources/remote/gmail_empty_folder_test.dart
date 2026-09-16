import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/gmail_datasource_impl.dart';

import 'gmail_empty_folder_test.mocks.dart';

/// Gmail has no "empty folder" endpoint, so what this does is entirely in the
/// requests it makes: which ids it asks for, and what it writes onto them.
/// Both halves have a silent failure mode — a listing that hides spam by
/// default returns nothing to delete, and a modify that leaves the source
/// label on leaves the folder listing exactly as it was — so this pins the
/// request shapes rather than the method returning.
@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GmailDatasourceImpl datasource;

  /// Pages handed back by `messages.list`, in order. The empty one at the end
  /// is how the loop learns it is done.
  late List<List<String>> pages;

  Map<String, dynamic> lastListQuery() =>
      (verify(mockDio.get<String>('/users/me/messages',
                  queryParameters: captureAnyNamed('queryParameters'),
                  options: anyNamed('options')))
              .captured
              .last as Map)
          .cast<String, dynamic>();

  List<Map<String, dynamic>> modifyBodies() =>
      verify(mockDio.post<void>('/users/me/messages/batchModify',
              data: captureAnyNamed('data')))
          .captured
          .map((d) => (d as Map).cast<String, dynamic>())
          .toList();

  setUp(() {
    mockDio = MockDio();
    datasource = GmailDatasourceImpl.withDio(mockDio);
    pages = [];

    var call = 0;
    when(mockDio.get<String>(
      '/users/me/messages',
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    )).thenAnswer((_) async {
      final page = call < pages.length ? pages[call] : const <String>[];
      call++;
      return Response<String>(
        data: jsonEncode({
          'messages': [for (final id in page) {'id': id}],
        }),
        statusCode: 200,
        requestOptions: RequestOptions(path: '/users/me/messages'),
      );
    });

    when(mockDio.post<void>('/users/me/messages/batchModify',
            data: anyNamed('data')))
        .thenAnswer((_) async => Response<void>(
              statusCode: 204,
              requestOptions:
                  RequestOptions(path: '/users/me/messages/batchModify'),
            ));
  });

  test('trashes every message carrying the label, and drops the label', () async {
    pages = [
      ['m1', 'm2'],
      ['m3'],
    ];

    await datasource.emptyFolder('SPAM');

    expect(modifyBodies(), [
      {
        'ids': ['m1', 'm2'],
        'addLabelIds': ['TRASH'],
        'removeLabelIds': ['SPAM'],
      },
      {
        'ids': ['m3'],
        'addLabelIds': ['TRASH'],
        'removeLabelIds': ['SPAM'],
      },
    ]);
  });

  // The listing hides SPAM and TRASH unless asked. Without this the folder the
  // user most often empties returns no ids at all, and an empty that touched
  // nothing reports success.
  test('asks for spam and trash explicitly', () async {
    pages = [
      ['m1'],
    ];

    await datasource.emptyFolder('SPAM');

    final query = lastListQuery();
    expect(query['includeSpamTrash'], true);
    expect(query['labelIds'], 'SPAM');
  });

  // The ids are re-listed rather than paged: each batch stops carrying the
  // label, so the next listing is the next page — and a page token minted
  // before the labels moved is not. A listing that comes back unchanged is
  // therefore a modify that answered 200 without taking, and reporting success
  // there is the silent-empty shape all over again: the repository clears the
  // folder's cache on the strength of it.
  test('fails rather than reporting a folder emptied that it could not empty',
      () async {
    // A server that keeps answering with the same ids — what a modify that
    // reported success without removing the label would look like from here.
    when(mockDio.get<String>(
      '/users/me/messages',
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    )).thenAnswer((_) async => Response<String>(
          data: jsonEncode({
            'messages': [
              {'id': 'm1'}
            ],
          }),
          statusCode: 200,
          requestOptions: RequestOptions(path: '/users/me/messages'),
        ));

    await expectLater(
      datasource.emptyFolder('SPAM'),
      throwsA(isA<ServerException>()),
    );

    // And it stopped after the one attempt rather than looping on it.
    expect(modifyBodies(), hasLength(1));
  });

  // `deleteFolder` resolves a `__virtual__` id to the descendants that are all
  // it is, because deleting a label takes no message anywhere. Emptying does,
  // so a folder segment that carries no label of its own is refused rather
  // than turned into a delete of mail in folders the user did not name.
  test('refuses a folder that is only a path segment', () async {
    await expectLater(
      datasource.emptyFolder('__virtual__Clients'),
      throwsA(isA<ServerException>()),
    );

    verifyNever(mockDio.get<String>(
      '/users/me/messages',
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    ));
  });

  // Emptying the trash is a permanent delete however it is asked for, and the
  // menu item that withholds it is decided from a different source of truth
  // (AccountCubit) than the datasource that runs it.
  test('refuses the trash even without the permanent flag', () async {
    await expectLater(
      datasource.emptyFolder('TRASH'),
      throwsA(isA<ServerException>()),
    );

    verifyNever(mockDio.post<void>('/users/me/messages/batchModify',
        data: anyNamed('data')));
  });

  test('an empty folder writes nothing', () async {
    await datasource.emptyFolder('Label_9');

    verifyNever(mockDio.post<void>('/users/me/messages/batchModify',
        data: anyNamed('data')));
  });

  // `messages.batchDelete` needs the full `https://mail.google.com/` scope,
  // which the app does not hold — so this fails before asking rather than
  // spending a round trip on a 403. The menu item is withheld on a Gmail trash
  // folder; this is the backstop.
  test('refuses a permanent delete without listing anything', () async {
    await expectLater(
      datasource.emptyFolder('TRASH', permanentDelete: true),
      throwsA(isA<ServerException>()),
    );

    verifyNever(mockDio.get<String>(
      '/users/me/messages',
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    ));
  });

  test('maps a server error to a ServerException', () async {
    pages = [
      ['m1'],
    ];
    when(mockDio.post<void>('/users/me/messages/batchModify',
            data: anyNamed('data')))
        .thenThrow(DioException(
      requestOptions: RequestOptions(path: '/users/me/messages/batchModify'),
      response: Response(
        statusCode: 500,
        requestOptions:
            RequestOptions(path: '/users/me/messages/batchModify'),
      ),
    ));

    await expectLater(
      datasource.emptyFolder('SPAM'),
      throwsA(isA<ServerException>()),
    );
  });
}
