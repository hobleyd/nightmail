import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/sync/imap_connection_gate.dart';

void main() {
  late ImapConnectionGate gate;

  setUp(() => gate = ImapConnectionGate());

  test('two callers for the same account never overlap', () async {
    final log = <String>[];
    var active = 0;
    var sawOverlap = false;

    Future<void> unit(String label) => gate.runExclusive('acct-1', () async {
          active++;
          if (active > 1) sawOverlap = true;
          log.add('start:$label');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          log.add('end:$label');
          active--;
        });

    await Future.wait([unit('a'), unit('b'), unit('c')]);

    expect(sawOverlap, isFalse);
    expect(log, ['start:a', 'end:a', 'start:b', 'end:b', 'start:c', 'end:c']);
  });

  test('different accounts run concurrently, not serialized', () async {
    final order = <String>[];
    final unblockA = Completer<void>();

    final futureA = gate.runExclusive('acct-a', () async {
      order.add('a-start');
      await unblockA.future;
      order.add('a-end');
    });
    // Give acct-a's body a chance to start and block before acct-b runs.
    await Future<void>.delayed(Duration.zero);
    final futureB = gate.runExclusive('acct-b', () async {
      order.add('b-start');
      order.add('b-end');
    });

    await futureB;
    expect(order, contains('b-start'));
    expect(order, contains('b-end'));
    // acct-b finished without waiting on acct-a, which is still blocked.
    expect(order.contains('a-end'), isFalse);

    unblockA.complete();
    await futureA;
  });

  test("one caller's failure doesn't wedge the next caller's turn", () async {
    var secondRan = false;

    await expectLater(
      gate.runExclusive('acct-1', () async => throw StateError('boom')),
      throwsStateError,
    );

    await gate.runExclusive('acct-1', () async {
      secondRan = true;
    });

    expect(secondRan, isTrue);
  });
}
