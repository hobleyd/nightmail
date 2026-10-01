import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/widgets/recipient_input_field.dart';

/// An address book whose answers arrive after [delay], or never — the shape
/// of the fault `RecipientInputField.searchTimeout` is for. Drives the
/// no-account path, which reads the OS address book directly.
class _SlowSystemContacts implements SystemContactsRepository {
  _SlowSystemContacts({this.delay});

  /// Null means the lookup never completes.
  final Duration? delay;
  int searches = 0;

  @override
  Future<List<ContactSuggestion>> search(String query) {
    searches++;
    final delay = this.delay;
    if (delay == null) return Completer<List<ContactSuggestion>>().future;
    return Future.delayed(
      delay,
      () => const [ContactSuggestion(address: 'alice@example.com', name: 'Alice')],
    );
  }

  @override
  Future<void> warmUp() async {}

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<ContactSuggestion>> fetchAll() async => const [];
}

Widget _field() => MaterialApp(
      home: Scaffold(
        body: RecipientInputField(
          label: 'To',
          recipients: const [],
          onChanged: (_) {},
        ),
      ),
    );

/// Runs [body] with [debugPrint] collecting into the returned list, restored
/// before the test body ends — the test binding checks it was put back.
Future<List<String>> _capturingDebugPrint(
  Future<void> Function(List<String> lines) body,
) async {
  final lines = <String>[];
  final previous = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) => lines.add(message ?? '');
  try {
    await body(lines);
  } finally {
    debugPrint = previous;
  }
  return lines;
}

void main() {
  group('RecipientInputField.searchTimeout', () {
    testWidgets('a lookup that never answers is given up on and logged',
        (tester) async {
      final contacts = _SlowSystemContacts(delay: null);
      sl.registerLazySingleton<SystemContactsRepository>(() => contacts);
      addTearDown(sl.reset);

      await _capturingDebugPrint((lines) async {
        await tester.pumpWidget(_field());
        await tester.enterText(find.byType(TextField), 'ali');
        // The debounce fires and the lookup is dispatched.
        await tester.pump(const Duration(milliseconds: 250));
        expect(contacts.searches, 1);
        expect(lines, isEmpty);

        await tester.pump(RecipientInputField.searchTimeout);

        expect(lines, hasLength(1));
        expect(
          lines.single,
          '[NightMail] recipient search timed out after 5 s '
          '(account none, 3-char query)',
        );
        expect(find.byType(ListTile), findsNothing);
      });
    });

    testWidgets('a lookup that answers in time is not reported',
        (tester) async {
      final contacts = _SlowSystemContacts(delay: const Duration(seconds: 1));
      sl.registerLazySingleton<SystemContactsRepository>(() => contacts);
      addTearDown(sl.reset);

      await _capturingDebugPrint((lines) async {
        await tester.pumpWidget(_field());
        await tester.enterText(find.byType(TextField), 'ali');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(seconds: 1));

        expect(find.text('Alice'), findsOneWidget);

        // Well past the timeout: the answer cancelled it.
        await tester.pump(RecipientInputField.searchTimeout * 2);

        expect(lines, isEmpty);
      });
    });
  });
}
