import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/marquee_text.dart';

/// The Chat pane's conversation name: still when it fits, otherwise to its
/// end and back, resting at each end.
void main() {
  const long = 'A channel name far too long to fit in the pane at all';

  Future<void> show(WidgetTester tester, String text,
      {double width = 120, bool disableAnimations = false}) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Center(
          child: SizedBox(
            width: width,
            child: MarqueeText(text, style: const TextStyle(fontSize: 14)),
          ),
        ),
      ),
    ));
  }

  double dx(WidgetTester tester) => tester
      .widget<Transform>(find.descendant(
          of: find.byType(MarqueeText), matching: find.byType(Transform)))
      .transform
      .getTranslation()
      .x;

  testWidgets('text that fits sits still with no ticker', (tester) async {
    await show(tester, 'Ann Lee', width: 300);
    expect(find.descendant(
        of: find.byType(MarqueeText), matching: find.byType(Transform)),
        findsNothing);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('text too long rests, scrolls to its end, rests, and comes back',
      (tester) async {
    await show(tester, long);
    expect(dx(tester), 0);

    // Still resting at the start.
    await tester.pump(const Duration(milliseconds: 500));
    expect(dx(tester), 0);

    // Moving left.
    await tester.pump(const Duration(milliseconds: 1500));
    final moving = dx(tester);
    expect(moving, lessThan(0));

    // Over 40 s it reaches its end exactly — the whole name read.
    double? far;
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final x = dx(tester);
      if (far == null || x < far) far = x;
    }
    final painter = TextPainter(
      text: const TextSpan(text: long, style: TextStyle(fontSize: 14)),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(far, closeTo(120 - painter.width, 1));
    painter.dispose();

    // And it comes back to the start.
    double? near;
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final x = dx(tester);
      if (near == null || x > near) near = x;
    }
    expect(near, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with animations off it shows an ellipsis instead',
      (tester) async {
    await show(tester, long, disableAnimations: true);
    expect(find.descendant(
        of: find.byType(MarqueeText), matching: find.byType(Transform)),
        findsNothing);
    final text = tester.widget<Text>(find.text(long));
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('a new text starts again from the beginning', (tester) async {
    await show(tester, long);
    await tester.pump(const Duration(seconds: 2));
    expect(dx(tester), lessThan(0));
    await show(tester, '$long, renamed');
    expect(dx(tester), 0);
    await tester.pumpWidget(const SizedBox());
  });
}
