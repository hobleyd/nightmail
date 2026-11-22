import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/change_stream_datasource.dart';
import 'package:nightmail/domain/entities/graph_endpoints.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/sync/change_stream_service.dart';

const _url = 'https://mail.example.com/graph/nightware/v1/changes';

MicrosoftAccount _account(String id) => MicrosoftAccount(
      id: id,
      displayName: id,
      emailAddress: '$id@example.com',
      tenantId: MicrosoftAccount.nightmailServerTenantId,
      server: const GraphEndpoints(
        graphBaseUrl: 'https://mail.example.com/graph/v1.0',
        graphBetaBaseUrl: 'https://mail.example.com/graph/beta',
        authorizationEndpoint: 'https://mail.example.com/authorize',
        tokenEndpoint: 'https://mail.example.com/token',
        serverUrl: 'https://mail.example.com',
        changesUrl: _url,
      ),
    );

/// Hands out one controller per connection, so a test plays the server.
class _Server {
  final List<(String, StreamController<ChangeStreamEvent>)> connections = [];

  Stream<ChangeStreamEvent> open(Account account) {
    final c = StreamController<ChangeStreamEvent>();
    connections.add((account.id, c));
    return c.stream;
  }

  StreamController<ChangeStreamEvent> last(String id) =>
      connections.lastWhere((c) => c.$1 == id).$2;

  int opened(String id) => connections.where((c) => c.$1 == id).length;
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late _Server server;
  late ChangeStreamService service;
  late List<ChangeSignal> signals;

  setUp(() {
    server = _Server();
    service = ChangeStreamService(
      targetFor: (a) => a is MicrosoftAccount && a.server?.changesUrl != null
          ? (url: a.server!.changesUrl!, mailbox: null)
          : null,
      open: server.open,
      backoff: (_) => const Duration(milliseconds: 5),
    );
    signals = [];
    service.signals.listen(signals.add);
  });

  tearDown(() => service.dispose());

  test('relays ready and changed as signals for the account', () async {
    service.watch([_account('a')]);
    server.last('a')
      ..add(const ChangeStreamReady({'mail', 'calendar'}))
      ..add(const ChangeStreamChanged({'mail'}));
    await _settle();

    expect(signals.map((s) => s.accountId), ['a', 'a']);
    expect(signals.map((s) => s.isReady), [true, false]);
    expect(signals.first.areas, {'mail', 'calendar'});
    expect(signals.last.areas, {'mail'});
    expect(signals.last.concerns('mail'), isTrue);
    expect(signals.last.concerns('calendar'), isFalse);
  });

  test('an account with no stream is not watched', () async {
    service.watch([
      const MicrosoftAccount(
          id: 'm', displayName: 'm', emailAddress: 'm@x.com', tenantId: 't'),
    ]);
    await _settle();

    expect(server.connections, isEmpty);
    expect(service.watchedAccountIds, isEmpty);
  });

  test('watching again keeps the connection; dropping the account closes it',
      () async {
    service.watch([_account('a')]);
    service.watch([_account('a')]);
    await _settle();
    expect(server.opened('a'), 1);

    final connection = server.last('a');
    var cancelled = false;
    connection.onCancel = () => cancelled = true;
    service.watch(const []);
    await _settle();

    expect(cancelled, isTrue);
    expect(service.watchedAccountIds, isEmpty);
  });

  test('a stream the server closes after ready reconnects', () async {
    service.watch([_account('a')]);
    server.last('a')
      ..add(const ChangeStreamReady({'mail'}))
      ..add(const ChangeStreamEnded('expired'));
    await server.last('a').close();
    await _settle();

    expect(server.opened('a'), 2);
  });

  test('a failed connection is retried after the backoff', () async {
    final pauses = <int>[];
    final failing = ChangeStreamService(
      targetFor: (a) => (url: _url, mailbox: null),
      open: server.open,
      backoff: (failures) {
        pauses.add(failures);
        return const Duration(milliseconds: 5);
      },
    );
    addTearDown(failing.dispose);

    failing.watch([_account('b')]);
    server.last('b').addError(StateError('404'));
    await _settle();
    server.last('b').addError(StateError('404'));
    await _settle();

    expect(server.opened('b'), 3);
    expect(pauses, containsAllInOrder([1, 2]));
  });

  test('the default backoff starts at 2 s and caps at 2 min', () {
    expect(ChangeStreamService.defaultBackoff(0), const Duration(seconds: 1));
    expect(ChangeStreamService.defaultBackoff(1), const Duration(seconds: 2));
    expect(ChangeStreamService.defaultBackoff(3), const Duration(seconds: 8));
    expect(ChangeStreamService.defaultBackoff(20), const Duration(minutes: 2));
  });

  test('a closed account is never reconnected', () async {
    service.watch([_account('a')]);
    service.watch(const []);
    await server.last('a').close();
    await _settle();

    expect(server.opened('a'), 1);
  });
}
