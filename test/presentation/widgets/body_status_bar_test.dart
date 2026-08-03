import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/body_status_bar.dart';
import 'package:nightmail/presentation/widgets/hovered_link_chip.dart';

void main() {
  const url = 'https://example.com/newsletter/click?id=42';

  late int downloadOnce;
  late int alwaysDownload;

  setUp(() {
    downloadOnce = 0;
    alwaysDownload = 0;
  });

  Future<void> pumpBar(
    WidgetTester tester, {
    String? hoveredLink,
    bool imagesBlocked = false,
    double width = 800,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: Column(
            children: [
              const Expanded(child: SizedBox.expand()),
              BodyStatusBar(
                hoveredLink: hoveredLink,
                imagesBlocked: imagesBlocked,
                onDownloadOnce: () => downloadOnce++,
                onAlwaysDownload: () => alwaysDownload++,
              ),
            ],
          ),
        ),
      ),
    ));
  }

  group('BodyStatusBar', () {
    testWidgets('takes no height with nothing to report', (tester) async {
      await pumpBar(tester);

      expect(find.byType(HoveredLinkChip), findsNothing);
      expect(find.text('Download once'), findsNothing);
      expect(tester.getSize(find.byType(BodyStatusBar)).height, 0);
    });

    testWidgets('shows the hovered link on its own', (tester) async {
      await pumpBar(tester, hoveredLink: url);

      expect(find.byType(HoveredLinkChip), findsOneWidget);
      expect(find.text(url), findsOneWidget);
      expect(find.text('Download once'), findsNothing);
      expect(tester.getSize(find.byType(BodyStatusBar)).height,
          BodyStatusBar.height);
    });

    testWidgets('shows the blocked-image notice on its own', (tester) async {
      await pumpBar(tester, imagesBlocked: true);

      expect(find.text('External images blocked'), findsOneWidget);
      expect(find.text('Download once'), findsOneWidget);
      expect(find.byType(HoveredLinkChip), findsNothing);
    });

    testWidgets('keeps both image actions reachable behind a hovered link',
        (tester) async {
      await pumpBar(tester, hoveredLink: url, imagesBlocked: true);

      expect(find.byType(HoveredLinkChip), findsOneWidget);
      // The wording gives way to the link; the buttons do not.
      expect(find.text('External images blocked'), findsNothing);
      expect(find.byIcon(Icons.hide_image_outlined), findsOneWidget);

      await tester.tap(find.text('Download once'));
      await tester.tap(find.text('Always download'));
      await tester.pump();

      expect(downloadOnce, 1);
      expect(alwaysDownload, 1);
      // Still one bar, not two stacked.
      expect(tester.getSize(find.byType(BodyStatusBar)).height,
          BodyStatusBar.height);
    });

    testWidgets('ellipsises a long link rather than overflowing the strip',
        (tester) async {
      await pumpBar(
        tester,
        hoveredLink: 'https://example.com/${'segment/' * 30}end',
        imagesBlocked: true,
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(HoveredLinkChip), findsOneWidget);
      expect(find.text('Download once'), findsOneWidget);
      expect(find.text('Always download'), findsOneWidget);
    });

    testWidgets('drops the link when the pane is too narrow for both',
        (tester) async {
      await pumpBar(tester, hoveredLink: url, imagesBlocked: true, width: 380);

      expect(find.byType(HoveredLinkChip), findsNothing);
      // Back to the images-only presentation, wording included.
      expect(find.text('External images blocked'), findsOneWidget);
      expect(find.text('Download once'), findsOneWidget);
      // The test font is far wider than the real one (every glyph is a square
      // of the font size), so the buttons alone overstuff this width here. What
      // this test pins is the link giving way, not the strip's own minimum.
      tester.takeException();
    });
  });
}
