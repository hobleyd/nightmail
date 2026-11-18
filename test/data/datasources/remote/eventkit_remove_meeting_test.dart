import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/eventkit_calendar_datasource_impl.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('au.com.sharpblue.nightmail/eventkit');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  String ics({String? recurrenceId}) => [
        'BEGIN:VCALENDAR',
        'METHOD:CANCEL',
        'BEGIN:VEVENT',
        'UID:meeting-1@example.com',
        'SUMMARY:Weekly 1:1',
        'DTSTART:20261111T043000Z',
        'DTEND:20261111T053000Z',
        if (recurrenceId != null) 'RECURRENCE-ID:$recurrenceId',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n');

  group('EventKitCalendarDatasourceImpl.removeMeetingFromCalendar', () {
    test('names the cancelled occurrence to the native side', () async {
      // Regression: only the UID was sent, and the native side removed the
      // series' first occurrence whichever one had been cancelled.
      await EventKitCalendarDatasourceImpl().removeMeetingFromCalendar(
          emailId: 'msg-1', icsData: ics(recurrenceId: '20261111T043000Z'));

      expect(calls.single.method, 'deleteEventByUID');
      expect(calls.single.arguments, {
        'uid': 'meeting-1@example.com',
        'occurrenceStartMs':
            DateTime.utc(2026, 11, 11, 4, 30).millisecondsSinceEpoch,
      });
    });

    test('sends no occurrence for a whole-meeting cancellation', () async {
      await EventKitCalendarDatasourceImpl().removeMeetingFromCalendar(
          emailId: 'msg-1', icsData: ics());

      expect(calls.single.arguments, {'uid': 'meeting-1@example.com'});
    });
  });
}
