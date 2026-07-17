import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/repositories/spam_filter_repository_impl.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProviderPlatform(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

const _addr = EmailAddress(address: 'a@b.com', name: 'A');

Email _email(String id, {required String subject, required String body}) =>
    Email(
      id: id,
      subject: subject,
      from: _addr,
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: body,
      body: body,
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime(2026),
      importance: EmailImportance.normal,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const accountId = 'acct-shared';
  final spamEmails = [
    for (var i = 0; i < 8; i++)
      _email('spam-$i',
          subject: 'Win a free prize now',
          body: 'act now limited offer click here to claim'),
  ];
  final hamEmails = [
    for (var i = 0; i < 8; i++)
      _email('ham-$i',
          subject: 'Project meeting notes',
          body: 'agenda for tomorrow discussion points budget'),
  ];

  test(
      'exportState/importState round-trips training so a second device '
      'converges on the same classifier without training locally', () async {
    final dirA = await Directory.systemTemp.createTemp('spam_filter_test_a');
    final dirB = await Directory.systemTemp.createTemp('spam_filter_test_b');
    addTearDown(() async {
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });

    // Device A trains locally (mirrors _onJunkReported / _classifyAndTrainIfImap).
    PathProviderPlatform.instance = _FakePathProviderPlatform(dirA.path);
    final deviceA = SpamFilterRepositoryImpl();
    await deviceA.trainSpam(accountId, spamEmails);
    await deviceA.trainHam(accountId, hamEmails);
    final exported = await deviceA.exportState(accountId);

    // Device B has never trained this account locally — before import, it
    // has no training data and classifies nothing as spam.
    PathProviderPlatform.instance = _FakePathProviderPlatform(dirB.path);
    final deviceB = SpamFilterRepositoryImpl();
    final beforeImport = await deviceB.classifyEmails(accountId, spamEmails);
    expect(beforeImport, isEmpty);

    // After importing device A's exported state (simulating a SPAMDB pull),
    // device B classifies new spam-shaped mail the same way device A would.
    await deviceB.importState(accountId, exported);
    final newSpam = _email('spam-new',
        subject: 'Win a free prize now',
        body: 'act now limited offer click here to claim');
    final afterImport = await deviceB.classifyEmails(accountId, [newSpam]);
    expect(afterImport, contains(newSpam.id));
  });

  test('importState overwrites local training (last-write-wins)', () async {
    final dir = await Directory.systemTemp.createTemp('spam_filter_test_c');
    addTearDown(() => dir.delete(recursive: true));
    PathProviderPlatform.instance = _FakePathProviderPlatform(dir.path);

    final repo = SpamFilterRepositoryImpl();
    await repo.trainSpam(accountId, spamEmails);
    expect((await repo.exportState(accountId))['totalSpam'], greaterThan(0));

    // A remote import (e.g. another client pushed an empty/reset DB) must
    // replace local state wholesale, not merge with it.
    await repo.importState(accountId, const {
      'spamWords': <String, dynamic>{},
      'hamWords': <String, dynamic>{},
      'totalSpam': 0,
      'totalHam': 0,
      'trainedIds': <String>[],
    });

    final exported = await repo.exportState(accountId);
    expect(exported['totalSpam'], 0);
  });
}
