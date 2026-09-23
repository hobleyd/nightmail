// The due-date menu used to open on secondary tap only, which touch has no
// way to produce. On a touch platform a long press opens it; on the desktop
// the long press stays inert so it cannot collide with drag-and-drop.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/flag_icon_button.dart';

/// Runs [body] with the target platform overridden, restoring it before the
/// test framework checks that no debug variable was left changed.
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

Future<void> pump(WidgetTester tester) => tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: FlagIconButton(onTap: () {}, onSchedule: (_) {}),
        ),
      ),
    ));

void main() {
  testWidgets('on iOS a long press opens the due-date menu', (tester) async {
    await onPlatform(TargetPlatform.iOS, () async {
      await pump(tester);
      await tester.longPress(find.byType(FlagIconButton));
      await tester.pumpAndSettle();

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Next Week'), findsOneWidget);
    });
  });

  testWidgets('on Android too', (tester) async {
    await onPlatform(TargetPlatform.android, () async {
      await pump(tester);
      await tester.longPress(find.byType(FlagIconButton));
      await tester.pumpAndSettle();

      expect(find.text('Today'), findsOneWidget);
    });
  });

  testWidgets('on macOS a long press does nothing', (tester) async {
    await onPlatform(TargetPlatform.macOS, () async {
      await pump(tester);
      await tester.longPress(find.byType(FlagIconButton));
      await tester.pumpAndSettle();

      expect(find.text('Today'), findsNothing);
    });
  });

  testWidgets('the tap target is at least 48pt on touch', (tester) async {
    await onPlatform(TargetPlatform.iOS, () async {
      await pump(tester);
      final size = tester.getSize(find.byType(IconButton));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    });
  });
}
