import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/gmail_datasource_impl.dart';

import 'gmail_delete_folder_test.mocks.dart';

/// A Gmail "folder" is a label, and its children are separate labels that
/// merely share its name as a path prefix — so deleting `Vendors` on its own
/// leaves `Vendors/Datadog` behind, promoted to a root folder. Which labels
/// this deletes is therefore the whole of the behaviour, and none of it is
/// visible from the endpoint being called.
@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GmailDatasourceImpl datasource;

  /// Deliberately includes `Vendors Archive`: a sibling whose name starts with
  /// the folder's own is not inside it, and deleting one would be the
  /// destructive half of this feature firing on a folder nobody named.
  const labels = [
    {'id': 'label-1', 'name': 'Vendors'},
    {'id': 'label-2', 'name': 'Vendors/Datadog'},
    {'id': 'label-3', 'name': 'Vendors/Datadog/Invoices'},
    {'id': 'label-4', 'name': 'Vendors Archive'},
    {'id': 'label-5', 'name': 'Receipts'},
    // No label named `Clients` — the panel draws that segment as a virtual
    // folder purely because this one lives under it.
    {'id': 'label-6', 'name': 'Clients/Acme'},
    {'id': 'INBOX', 'name': 'INBOX'},
  ];

  List<String> deletedPaths() => verify(mockDio.delete<void>(captureAny))
      .captured
      .cast<String>()
      .toList();

  setUp(() {
    mockDio = MockDio();
    datasource = GmailDatasourceImpl.withDio(mockDio);

    when(mockDio.get<Map<String, dynamic>>('/users/me/labels')).thenAnswer(
      (_) async => Response(
        data: const {'labels': labels},
        statusCode: 200,
        requestOptions: RequestOptions(path: '/users/me/labels'),
      ),
    );
    when(mockDio.delete<void>(any)).thenAnswer((inv) async => Response<void>(
          statusCode: 204,
          requestOptions:
              RequestOptions(path: inv.positionalArguments.first as String),
        ));
  });

  test('deletes the label and every label beneath it, and nothing else',
      () async {
    await datasource.deleteFolder(folderId: 'label-1');

    expect(
      deletedPaths(),
      unorderedEquals([
        '/users/me/labels/label-1',
        '/users/me/labels/label-2',
        '/users/me/labels/label-3',
      ]),
    );
  });

  test('a virtual folder deletes the descendants that are all it is',
      () async {
    // `__virtual__` is the id of a path segment carrying no label of its own —
    // a folder the panel draws because something lives under it. The
    // descendants are the only thing there is to delete, and the path is read
    // from the id rather than looked up, since no label answers to it.
    await datasource.deleteFolder(folderId: '__virtual__Clients');

    expect(deletedPaths(), ['/users/me/labels/label-6']);
  });

  test('an id no label answers to deletes nothing', () async {
    // Better a failure the caller reports than a path resolved to '' — which
    // the prefix match below would take as the root of every label there is.
    await expectLater(
      datasource.deleteFolder(folderId: 'label-gone'),
      throwsA(isA<ServerException>()),
    );
    verifyNever(mockDio.delete<void>(any));
  });
}
