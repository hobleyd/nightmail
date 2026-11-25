import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/chat/chat_conversation_row.dart';

void main() {
  final now = DateTime(2026, 11, 26, 10);

  test('today is the time alone', () {
    expect(chatMessageWhen(DateTime(2026, 11, 26, 9, 5), now: now), '9:05\u202fAM');
  });

  test('yesterday says so', () {
    expect(chatMessageWhen(DateTime(2026, 11, 25, 15, 4), now: now),
        'Yesterday 3:04\u202fPM');
  });

  test('earlier this year has the weekday and date', () {
    expect(chatMessageWhen(DateTime(2026, 11, 24, 15, 4), now: now),
        'Tue 24 Nov 3:04\u202fPM');
  });

  test('another year has the year', () {
    expect(chatMessageWhen(DateTime(2025, 11, 24, 15, 4), now: now),
        '24 Nov 2025 3:04\u202fPM');
  });
}
