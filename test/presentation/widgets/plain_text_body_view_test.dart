import 'dart:convert';

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

  const composeChannel = MethodChannel('mixin.one/desktop_multi_window');
  const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');

  // Opening a compose window asks the current window where it is first, so the
  // new one can be centred on the same screen. Left unmocked the call never
  // completes — there is no engine behind it to answer — and the compose future
  // hangs before it ever reaches [composeChannel]. Null is what the real helper
  // falls back to anyway.
  const screenChannel = MethodChannel('au.com.sharpblue.nightmail/window_utils');

  // url_launcher's default implementation is a method channel, and no plugin is
  // registered in a widget test, so the launch is recorded here instead.
  final launched = <String>[];

  /// The arguments of each compose sub-window opened, as the JSON string
  /// `desktop_multi_window` would carry across the window boundary.
  final composed = <String>[];

  void mock(
    MethodChannel channel,
    Future<Object?>? Function(MethodCall)? handler,
  ) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    launched.clear();
    composed.clear();
    mock(launcherChannel, (call) async {
      if (call.method == 'launch') {
        launched.add((call.arguments as Map)['url'] as String);
      }
      return true;
    });
    mock(composeChannel, (call) async {
      if (call.method == 'createWindow') {
        composed.add((call.arguments as Map)['arguments'] as String);
      }
      return '2';
    });
    mock(screenChannel, (call) async => null);
  });

  tearDown(() {
    mock(launcherChannel, null);
    mock(composeChannel, null);
    mock(screenChannel, null);
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

  /// The offset of [needle] within [text] as the paragraph rendered it.
  Offset centreOf(WidgetTester tester, String text, String needle) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byType(RichText).first,
    );
    final box = paragraph
        .getBoxesForSelection(TextSelection(
          baseOffset: text.indexOf(needle),
          extentOffset: text.indexOf(needle) + needle.length,
        ))
        .first;
    return tester.getTopLeft(find.byType(RichText).first) +
        Offset(box.left + 4, (box.top + box.bottom) / 2);
  }

  /// The offset of the URL inside the rendered paragraph.
  Offset urlCentre(WidgetTester tester) => centreOf(tester, body, url);

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

  testWidgets('an address is composed here, not handed to the OS',
      (tester) async {
    const addressBody = 'Ask helpdesk@example.com about it.';
    await pumpBody(tester, addressBody);

    await tester.tapAt(centreOf(tester, addressBody, 'helpdesk@example.com'));
    await tester.pumpAndSettle();

    expect(launched, isEmpty, reason: 'a mailto: must not leave the app');
    expect(composed, hasLength(1));
    final args = jsonDecode(composed.single) as Map<String, dynamic>;
    expect(args['mode'], 'newEmail');
    expect(
      (args['draftEmail'] as Map)['toRecipients'],
      [
        {'address': 'helpdesk@example.com', 'name': null}
      ],
    );
  });

  testWidgets('a mailto: URL carries its subject into the compose window',
      (tester) async {
    const mailtoBody = 'Use mailto:sam@example.com?subject=Leave%20request now.';
    await pumpBody(tester, mailtoBody);

    await tester.tapAt(centreOf(
      tester,
      mailtoBody,
      'mailto:sam@example.com?subject=Leave%20request',
    ));
    await tester.pumpAndSettle();

    expect(launched, isEmpty);
    final draft = (jsonDecode(composed.single) as Map)['draftEmail'] as Map;
    expect(draft['subject'], 'Leave request');
    expect(draft['toRecipients'], [
      {'address': 'sam@example.com', 'name': null}
    ]);
  });
}
