import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/google_drive_datasource_impl.dart';
import 'package:nightmail/data/datasources/remote/graph_drive_datasource_impl.dart';
import 'package:nightmail/domain/entities/cloud_document.dart';
import 'package:nightmail/domain/entities/cloud_file.dart';
import 'package:nightmail/infrastructure/auth/gmail_auth_service.dart';
import 'package:nightmail/infrastructure/auth/microsoft_auth_service.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';
import 'package:nightmail/infrastructure/http/google_drive_http_client.dart';
import 'package:nightmail/infrastructure/http/graph_http_client.dart';

/// The compose window's cloud picker: listing, downloading, checking access to
/// and sharing files over Graph (Microsoft 365 and a NightMail Server) and
/// Google Drive. HTTP is stubbed; the auth interceptor is removed.
typedef _Handler = ResponseBody Function(RequestOptions options);

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ResponseBody _bytes(List<int> bytes) =>
    ResponseBody.fromBytes(bytes, 200, headers: const {
      Headers.contentTypeHeader: ['application/octet-stream'],
    });

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);
  final _Handler handler;
  final seen = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    seen.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

(GraphDriveDatasourceImpl, _StubAdapter) _graph(
  _Handler handler, {
  CloudDriveProvider provider = CloudDriveProvider.microsoft,
}) {
  final client = GraphHttpClient(
    authService: MicrosoftAuthService(
      clientId: 'c',
      tenantId: 'common',
      redirectUri: 'nightmail://auth',
      tokenStorage: TokenStorage(const FlutterSecureStorage()),
    ),
  );
  final adapter = _StubAdapter(handler);
  client.dio
    ..interceptors.clear()
    ..httpClientAdapter = adapter;
  return (
    GraphDriveDatasourceImpl(
        client: client, accountId: 'acc', provider: provider),
    adapter
  );
}

(GoogleDriveDatasourceImpl, _StubAdapter) _google(_Handler handler) {
  final client = GoogleDriveHttpClient(
    authService: GmailAuthService(
      clientId: 'c',
      clientSecret: 's',
      redirectUri: 'http://127.0.0.1',
      tokenStorage: TokenStorage(const FlutterSecureStorage()),
    ),
  );
  final adapter = _StubAdapter(handler);
  client.dio
    ..interceptors.clear()
    ..httpClientAdapter = adapter;
  return (GoogleDriveDatasourceImpl(client: client, accountId: 'g'), adapter);
}

void main() {
  group('Graph', () {
    test('lists My files folders first, skipping OneNote packages', () async {
      final (ds, adapter) = _graph((_) => _json({
            'value': [
              {'id': '1', 'name': 'b.docx', 'file': {'mimeType': 'x'}},
              {'id': '2', 'name': 'Zed', 'folder': {'childCount': 1}},
              {'id': '3', 'name': 'Notebook', 'package': {'type': 'oneNote'}},
              {'id': '4', 'name': 'a.pdf', 'file': {}},
            ],
          }));
      final files = await ds.listFiles();
      expect(adapter.seen.single.path, '/me/drive/root/children');
      expect(files.map((f) => f.name), ['Zed', 'a.pdf', 'b.docx']);
      expect(files.first.isFolder, isTrue);
      expect(files.every((f) => f.accountId == 'acc'), isTrue);
    });

    test('a sharedWithMe entry is addressed by its remote drive and id',
        () async {
      final (ds, adapter) = _graph((_) => _json({
            'value': [
              {
                'id': 'local',
                'name': 'Budget.xlsx',
                'remoteItem': {
                  'id': 'REMOTE',
                  'file': {'mimeType': 'x'},
                  'webUrl': 'https://contoso.sharepoint.com/Budget.xlsx',
                  'parentReference': {'driveId': 'b!drive'},
                },
              },
            ],
          }));
      final files =
          await ds.listFiles(collection: CloudFileCollection.sharedWithMe);
      expect(adapter.seen.single.path, '/me/drive/sharedWithMe');
      expect(files.single.id, 'REMOTE');
      expect(files.single.driveId, 'b!drive');
      expect(files.single.webUrl, 'https://contoso.sharepoint.com/Budget.xlsx');
    });

    test('opening a folder in another drive goes through /drives', () async {
      final (ds, adapter) = _graph((_) => _json({'value': []}));
      await ds.listFiles(
          folder: const CloudFile(
              accountId: 'acc',
              provider: CloudDriveProvider.microsoft,
              id: 'F1',
              driveId: 'b!d',
              name: 'Reports',
              isFolder: true));
      expect(adapter.seen.single.path, '/drives/b!d/items/F1/children');
    });

    test('a next link on another host is never followed', () async {
      final (ds, adapter) = _graph((_) => _json({
            'value': [
              {'id': '1', 'name': 'a', 'file': {}},
            ],
            '@odata.nextLink': 'https://evil.example/v1.0/next',
          }));
      await ds.listFiles();
      expect(adapter.seen, hasLength(1));
    });

    test('a NightMail Server has no sharedWithMe and searches its drive',
        () async {
      final (ds, adapter) = _graph((_) => _json({'value': []}),
          provider: CloudDriveProvider.nextcloud);
      expect(
          await ds.listFiles(collection: CloudFileCollection.sharedWithMe),
          isEmpty);
      expect(adapter.seen, isEmpty);
      await ds.searchFiles("Bob's");
      expect(adapter.seen.single.path, contains('/me/drive/root/search'));
      expect(adapter.seen.single.method, 'GET');
    });

    test('Microsoft search goes to /search/query', () async {
      final (ds, adapter) = _graph((_) => _json({
            'value': [
              {
                'hitsContainers': [
                  {
                    'hits': [
                      {
                        'resource': {
                          'id': 'S1',
                          'name': 'Plan.docx',
                          'parentReference': {'driveId': 'b!x'},
                          'webUrl': 'https://contoso.sharepoint.com/Plan.docx',
                        },
                      },
                    ],
                  },
                ],
              },
            ],
          }));
      final hits = await ds.searchFiles('plan');
      expect(adapter.seen.single.path, '/search/query');
      expect(hits.single.driveId, 'b!x');
    });

    test('checkAccess reads the permissions', () async {
      final (ds, _) = _graph((_) => _json({
            'value': [
              {
                'link': {'scope': 'organization'},
              },
            ],
          }));
      final access = await ds.checkAccess(
        const CloudFile(
            accountId: 'acc',
            provider: CloudDriveProvider.microsoft,
            id: 'I',
            name: 'x',
            isFolder: false),
        ['a@contoso.com', 'b@fabrikam.com'],
        organizationDomains: {'contoso.com'},
      );
      expect(access.recipientsWithoutAccess, ['b@fabrikam.com']);
    });

    test('a 403 on permissions means nothing to check or share', () async {
      final (ds, _) = _graph((_) => _json({
            'error': {'message': 'Access denied'},
          }, status: 403));
      final access = await ds.checkAccess(
        const CloudFile(
            accountId: 'acc',
            provider: CloudDriveProvider.microsoft,
            id: 'I',
            name: 'x',
            isFolder: false),
        ['b@fabrikam.com'],
        organizationDomains: const {},
      );
      expect(access.recipientsWithoutAccess, isEmpty);
      expect(access.canShare, isFalse);
    });

    test('shares one recipient per invite and reports each refusal', () async {
      final (ds, adapter) = _graph((options) {
        final body = options.data as Map<String, dynamic>;
        final email = (body['recipients'] as List).single['email'];
        expect(body['sendInvitation'], isFalse);
        expect(body['roles'], ['read']);
        return email == 'bad@x.com'
            ? _json({
                'error': {'message': 'External sharing is off'},
              }, status: 400)
            : _json({'value': []});
      });
      final result = await ds.shareFile(
        const CloudFile(
            accountId: 'acc',
            provider: CloudDriveProvider.microsoft,
            id: 'I',
            name: 'x',
            isFolder: false),
        ['ok@x.com', 'bad@x.com'],
      );
      expect(adapter.seen, hasLength(2));
      expect(adapter.seen.first.path, '/me/drive/items/I/invite');
      expect(result.failed, {'bad@x.com': 'External sharing is off'});
    });

    test('refuses to download a file past the attachment limit', () async {
      final (ds, adapter) = _graph((_) => _bytes([1]));
      await expectLater(
        ds.downloadFile(const CloudFile(
            accountId: 'acc',
            provider: CloudDriveProvider.microsoft,
            id: 'I',
            name: 'huge.zip',
            isFolder: false,
            size: 500 * 1024 * 1024)),
        throwsA(anything),
      );
      expect(adapter.seen, isEmpty);
    });
  });

  group('Google Drive', () {
    test('a shortcut stands in for its target; folders are folders', () async {
      final (ds, adapter) = _google((_) => _json({
            'files': [
              {
                'id': 'SC',
                'name': 'Shortcut to Q3',
                'mimeType': 'application/vnd.google-apps.shortcut',
                'shortcutDetails': {
                  'targetId': 'TARGET',
                  'targetMimeType': 'application/vnd.google-apps.folder',
                },
              },
              {
                'id': 'D',
                'name': 'Notes',
                'mimeType': 'application/vnd.google-apps.document',
                'webViewLink': 'https://docs.google.com/document/d/D/edit',
              },
            ],
          }));
      final files = await ds.listFiles();
      expect(adapter.seen.single.queryParameters['q'],
          "'root' in parents and trashed = false");
      expect(files.first.id, 'TARGET');
      expect(files.first.isFolder, isTrue);
      expect(files.last.isGoogleEditorFile, isTrue);
    });

    test('a search escapes quotes', () async {
      final (ds, adapter) = _google((_) => _json({'files': []}));
      await ds.searchFiles("Bob's");
      expect(adapter.seen.single.queryParameters['q'],
          r"name contains 'Bob\'s' and trashed = false");
    });

    test('attaching a Google Doc exports it as .docx', () async {
      final (ds, adapter) = _google((_) => _bytes([1, 2, 3]));
      final doc = await ds.downloadFile(const CloudFile(
          accountId: 'g',
          provider: CloudDriveProvider.google,
          id: 'D',
          name: 'Notes',
          isFolder: false,
          mimeType: 'application/vnd.google-apps.document'));
      expect(adapter.seen.single.path, '/files/D/export');
      expect(doc.name, 'Notes.docx');
      expect(doc.contentType, contains('wordprocessingml'));
    });

    test('a recipient without a Google account gets Google\'s invitation',
        () async {
      final (ds, adapter) = _google((options) {
        if (options.queryParameters['sendNotificationEmail'] == 'false') {
          return _json({
            'error': {
              'message': 'You must check the Notify people box',
              'errors': [
                {'reason': 'invalidSharingRequest'},
              ],
            },
          }, status: 400);
        }
        return _json({'id': 'p'});
      });
      final result = await ds.shareFile(
        const CloudFile(
            accountId: 'g',
            provider: CloudDriveProvider.google,
            id: 'F',
            name: 'x',
            isFolder: false),
        ['outside@example.com'],
      );
      expect(result.failed, isEmpty);
      expect(adapter.seen, hasLength(2));
      expect(adapter.seen.last.queryParameters['sendNotificationEmail'], 'true');
    });
  });
}
