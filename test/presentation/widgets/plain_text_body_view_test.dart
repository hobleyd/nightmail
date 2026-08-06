import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/hovered_link_chip.dart';
import 'package:nightmail/presentation/widgets/plain_text_body_view.dart';

void main() {
  const url = 'https://intranet.example.com/app/timesheets';
  const body = 'Timesheets are at $url before Monday.';

  // url_launcher's default implementation is a method channel, and no plugin is
  // registered in a widget test, so the launch is recorded here instead.
  final launched = <String>[];

  setUp(() {
    launched.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        if (call.method == 'launch') {
          launched.add((call.arguments as Map)['url'] as String);
        }
        return true;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
  });

  Future<void> pumpBody(WidgetTester tester, String text) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 700,
          height: 400,
          child: PlainTextBodyView(text: text),
        ),
      ),
    ));
  }

  /// The offset of the URL inside the rendered paragraph.
  Offset urlCentre(WidgetTester tester) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byType(RichText).first,
    );
    final box = paragraph
        .getBoxesForSelection(TextSelection(
          baseOffset: body.indexOf(url),
          extentOffset: body.indexOf(url) + url.length,
        ))
        .first;
    return tester.getTopLeft(find.byType(RichText).first) +
        Offset(box.left + 4, (box.top + box.bottom) / 2);
  }

  testWidgets('opens a bare URL when it is tapped', (tester) async {
    await pumpBody(tester, body);

    await tester.tapAt(urlCentre(tester));
    await tester.pump();

    expect(launched, [url]);
  });

  testWidgets('a tap on the surrounding text opens nothing', (tester) async {
    await pumpBody(tester, body);

    await tester.tapAt(tester.getTopLeft(find.byType(RichText).first) +
        const Offset(4, 8));
    await tester.pump();

    expect(launched, isEmpty);
  });

  testWidgets('hovering a URL offers it for copying', (tester) async {
    await pumpBody(tester, body);
    expect(find.byType(HoveredLinkChip), findsNothing);

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(urlCentre(tester));
    await tester.pumpAndSettle();

    expect(find.byType(HoveredLinkChip), findsOneWidget);
    expect(
      tester.widget<HoveredLinkChip>(find.byType(HoveredLinkChip)).url,
      url,
    );
  });

  testWidgets('a body with no URL has nothing to report', (tester) async {
    await pumpBody(tester, 'Nothing to see here.');

    expect(find.byType(HoveredLinkChip), findsNothing);
    expect(find.text('Nothing to see here.'), findsOneWidget);
  });
}
