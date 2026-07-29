import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/error_snack_bar.dart';

void main() {
  const longError = 'HandshakeException: Handshake error in client '
      '(OS Error: WRONG_VERSION_NUMBER(tls_record.cc:242), errno = 0)';

  /// Captures whatever is written to the clipboard. `Clipboard.setData` goes
  /// out over [SystemChannels.platform], which has no implementation in tests.
  List<String> mockClipboard(WidgetTester tester) {
    final written = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          written.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    return written;
  }

  Future<void> pumpAndShow(
    WidgetTester tester,
    String message, {
    String? copyText,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showErrorSnackBar(context, message, copyText: copyText),
              child: const Text('fail'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('fail'));
    // Settle the entry animation — a single pump leaves the bar still sliding
    // up from below the viewport, where its buttons cannot be hit-tested.
    await tester.pumpAndSettle();
  }

  testWidgets('stays on screen well past the default snack bar timeout',
      (tester) async {
    await pumpAndShow(tester, longError);

    expect(find.text(longError), findsOneWidget);

    // The default SnackBar would have gone by now, taking an unread error
    // message with it.
    await tester.pump(const Duration(minutes: 10));
    expect(find.text(longError), findsOneWidget);
  });

  testWidgets('the copy button puts the error on the clipboard and closes the '
      'snack bar', (tester) async {
    final clipboard = mockClipboard(tester);
    await pumpAndShow(tester, longError);

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();

    expect(clipboard, [longError]);

    await tester.pumpAndSettle();
    expect(find.text(longError), findsNothing);
  });

  testWidgets('copies copyText when the clipboard should carry more than the '
      'visible message', (tester) async {
    final clipboard = mockClipboard(tester);
    await pumpAndShow(tester, 'Could not send', copyText: longError);

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();

    expect(clipboard, [longError]);
  });

  testWidgets('can still be dismissed by hand via the close icon',
      (tester) async {
    await pumpAndShow(tester, longError);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text(longError), findsNothing);
  });

  testWidgets('a second error replaces the first rather than queueing behind '
      'it forever', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => showErrorSnackBar(context, 'first error'),
                  child: const Text('fail once'),
                ),
                TextButton(
                  onPressed: () => showErrorSnackBar(context, 'second error'),
                  child: const Text('fail twice'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('fail once'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fail twice'));
    await tester.pumpAndSettle();

    expect(find.text('second error'), findsOneWidget);
    expect(find.text('first error'), findsNothing);
  });
}
