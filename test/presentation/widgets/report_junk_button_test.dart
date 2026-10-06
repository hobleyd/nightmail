import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/report_junk_button.dart';

/// The Report-junk button is a dropdown on desktop and a one-shot tap
/// everywhere else — see [ReportJunkButton].
///
/// The platform is overridden inside each test body and reset before it
/// returns: the test binding checks that no foundation debug variable is left
/// changed at the end of the body, which runs before any tearDown.
Future<void> _onPlatform(
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

void main() {
  late int junk;
  late int phishing;
  late int notJunk;

  setUp(() {
    junk = 0;
    phishing = 0;
    notJunk = 0;
  });

  Future<void> pump(WidgetTester tester, {bool isJunkFolder = false}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: ReportJunkButton(
            isJunkFolder: isJunkFolder,
            onReportJunk: () => junk++,
            onReportPhishing: () => phishing++,
            onNotJunk: () => notJunk++,
          ),
        ),
      ),
    ));
  }

  group('on desktop', () {
    testWidgets('a click opens a menu rather than acting', (tester) async {
      await _onPlatform(TargetPlatform.macOS, () async {
        await pump(tester);

        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();

        expect(find.text('Report junk'), findsOneWidget);
        expect(find.text('Report phishing'), findsOneWidget);
        expect(junk, 0);
        expect(phishing, 0);
      });
    });

    testWidgets('choosing Report junk reports junk', (tester) async {
      await _onPlatform(TargetPlatform.macOS, () async {
        await pump(tester);
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Report junk'));
        await tester.pumpAndSettle();

        expect(junk, 1);
        expect(phishing, 0);
        expect(find.text('Report phishing'), findsNothing);
      });
    });

    testWidgets('choosing Report phishing reports phishing', (tester) async {
      await _onPlatform(TargetPlatform.macOS, () async {
        await pump(tester);
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Report phishing'));
        await tester.pumpAndSettle();

        expect(phishing, 1);
        expect(junk, 0);
      });
    });

    testWidgets('dismissing the menu does nothing', (tester) async {
      await _onPlatform(TargetPlatform.macOS, () async {
        await pump(tester);
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();

        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(junk, 0);
        expect(phishing, 0);
        expect(notJunk, 0);
      });
    });

    testWidgets('in the Junk folder it is a plain Not-junk tap', (tester) async {
      await _onPlatform(TargetPlatform.macOS, () async {
        await pump(tester, isJunkFolder: true);

        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();

        expect(notJunk, 1);
        expect(find.text('Report phishing'), findsNothing);
        expect(find.byTooltip('Not junk'), findsOneWidget);
      });
    });
  });

  group('on a touch screen', () {
    testWidgets('a tap reports junk at once, with no menu', (tester) async {
      await _onPlatform(TargetPlatform.iOS, () async {
        await pump(tester);

        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();

        expect(junk, 1);
        expect(find.text('Report phishing'), findsNothing);
        expect(find.byTooltip('Report junk'), findsOneWidget);
      });
    });
  });
}
