import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/chat/chat_message_body.dart';

/// Chat bodies are rendered as text, not in a webview: markup becomes style,
/// images are never fetched, and only http(s)/mailto links are tappable.
void main() {
  Future<TextSpan> render(WidgetTester tester, String html) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatMessageBody(html: html, style: const TextStyle()),
      ),
    ));
    final text = tester.widget<Text>(find.byType(Text));
    return text.textSpan! as TextSpan;
  }

  List<TextSpan> leaves(InlineSpan span) {
    final out = <TextSpan>[];
    span.visitChildren((s) {
      if (s is TextSpan && s.text != null) out.add(s);
      return true;
    });
    return out;
  }

  testWidgets('bold, mentions and entities', (tester) async {
    final span = await render(
        tester, '<p>Hi <at id="0">Bob</at>, <b>ship</b> it &amp; go</p>');
    final parts = leaves(span);
    expect(parts.map((p) => p.text).join(), 'Hi @Bob, ship it & go');
    final bold = parts.firstWhere((p) => p.text == 'ship');
    expect(bold.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('images are never loaded; emoji keep their alt', (tester) async {
    final span = await render(tester,
        'a<img src="https://tracker.example/x.png">b<img alt="😀" src="x">');
    expect(leaves(span).map((p) => p.text).join(), 'a[image]b😀');
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('only http(s) and mailto links are tappable', (tester) async {
    final span = await render(tester,
        '<a href="https://example.com">ok</a> <a href="javascript:x()">bad</a>');
    final parts = leaves(span);
    expect(parts.firstWhere((p) => p.text == 'ok').recognizer,
        isA<TapGestureRecognizer>());
    expect(parts.firstWhere((p) => p.text == 'bad').recognizer, isNull);
  });

  testWidgets('script and style contents are dropped', (tester) async {
    final span = await render(
        tester, '<style>p{}</style><script>alert(1)</script><p>text</p>');
    expect(leaves(span).map((p) => p.text).join(), 'text');
  });
}
