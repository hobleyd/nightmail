import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/hovered_link_chip.dart';

void main() {
  const url = 'https://example.com/a/very/long/path?with=query&and=more';

  late List<String> copied;

  setUp(() => copied = []);

  Future<void> pumpChip(WidgetTester tester, {String link = url}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        // A narrow box, as in the toolbar: the URL has to ellipsise rather
        // than overflow.
        body: Center(child: SizedBox(width: 200, child: HoveredLinkChip(url: link))),
      ),
    ));
  }

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
  }

  group('HoveredLinkChip', () {
    testWidgets('shows the hovered URL', (tester) async {
      await pumpChip(tester);

      expect(find.text(url), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a click copies the URL to the clipboard', (tester) async {
      mockClipboard(tester);
      await pumpChip(tester);

      await tester.tap(find.byType(HoveredLinkChip));
      await tester.pump();

      expect(copied, [url]);
    });

    testWidgets('confirms the copy', (tester) async {
      mockClipboard(tester);
      await pumpChip(tester);

      await tester.tap(find.byType(HoveredLinkChip));
      await tester.pump();

      expect(find.text('Link copied to clipboard'), findsOneWidget);
    });

    testWidgets('copies the whole URL even though it is ellipsised',
        (tester) async {
      mockClipboard(tester);
      final long = 'https://example.com/${'segment/' * 40}end';
      await pumpChip(tester, link: long);

      await tester.tap(find.byType(HoveredLinkChip));
      await tester.pump();

      expect(copied, [long]);
    });
  });
}
