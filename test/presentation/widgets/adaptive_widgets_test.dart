// AdaptiveAlertDialog and AdaptiveSwitch take the Cupertino form on iOS only.
// Pinned against macOS in particular: the framework's own `.adaptive`
// constructors go Cupertino there too, which is the regression these exist
// to avoid.
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/adaptive_alert_dialog.dart';
import 'package:nightmail/presentation/widgets/adaptive_switch.dart';

Future<void> onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Widget _plainAlert() => AdaptiveAlertDialog(
      title: const Text('Delete folder?'),
      content: const Text('This cannot be undone.'),
      actions: [
        TextButton(onPressed: () {}, child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {},
          child: const Text('Delete', style: TextStyle(color: Colors.white)),
        ),
      ],
    );

Widget _formAlert() => AdaptiveAlertDialog(
      title: const Text('Rename'),
      content: const TextField(),
      actions: [TextButton(onPressed: () {}, child: const Text('Save'))],
    );

Future<void> pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));

void main() {
  group('AdaptiveAlertDialog', () {
    testWidgets('a plain alert is a Cupertino alert on iOS', (tester) async {
      await onPlatform(TargetPlatform.iOS, () async {
        await pump(tester, _plainAlert());
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        // Labels survive; the white-on-red styling does not come with them.
        final actions = tester
            .widgetList<CupertinoDialogAction>(find.byType(CupertinoDialogAction))
            .toList();
        expect(actions.length, 2);
        expect(actions[1].isDestructiveAction, isTrue);
        expect(actions[0].isDestructiveAction, isFalse);
        expect(find.text('Delete'), findsOneWidget);
      });
    });

    testWidgets('an alert with a form stays Material on iOS', (tester) async {
      await onPlatform(TargetPlatform.iOS, () async {
        await pump(tester, _formAlert());
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
      });
    });

    testWidgets('on macOS every alert stays Material', (tester) async {
      await onPlatform(TargetPlatform.macOS, () async {
        await pump(tester, _plainAlert());
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
      });
    });

    testWidgets('on Android too', (tester) async {
      await onPlatform(TargetPlatform.android, () async {
        await pump(tester, _plainAlert());
        expect(find.byType(AlertDialog), findsOneWidget);
      });
    });
  });

  group('AdaptiveSwitch', () {
    testWidgets('is a CupertinoSwitch on iOS and a Switch elsewhere',
        (tester) async {
      await onPlatform(TargetPlatform.iOS, () async {
        await pump(tester, AdaptiveSwitch(value: true, onChanged: (_) {}));
        expect(find.byType(CupertinoSwitch), findsOneWidget);
        expect(find.byType(Switch), findsNothing);
      });
      await onPlatform(TargetPlatform.macOS, () async {
        await pump(tester, AdaptiveSwitch(value: true, onChanged: (_) {}));
        expect(find.byType(Switch), findsOneWidget);
        expect(find.byType(CupertinoSwitch), findsNothing);
      });
      await onPlatform(TargetPlatform.android, () async {
        await pump(tester, AdaptiveSwitch(value: true, onChanged: (_) {}));
        expect(find.byType(Switch), findsOneWidget);
      });
    });
  });
}
