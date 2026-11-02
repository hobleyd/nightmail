import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/pages/compose_window.dart';

// The desktop list's Forward hands the compose window only ids and subjects,
// through the JSON its arguments travel as; the window fetches the .eml files.

void main() {
  test('forwarded messages survive the trip into the compose window', () {
    const messages = [
      (id: 'AAMkAG=', subject: 'Quarterly numbers'),
      (id: '19f8c30ceaff85df', subject: 'Ünïcödé — "quoted"'),
    ];

    final arguments = jsonDecode(jsonEncode({
      'forwardAsAttachments':
          ComposeWindowApp.forwardedMessagesToJson(messages),
    })) as Map<String, dynamic>;

    expect(
      ComposeWindowApp.forwardedMessagesFromJson(
          arguments['forwardAsAttachments']),
      messages,
    );
  });

  test('a malformed entry is skipped, and a missing subject is empty', () {
    expect(
      ComposeWindowApp.forwardedMessagesFromJson([
        {'subject': 'no id'},
        'not a map',
        {'id': 'm1'},
      ]),
      [(id: 'm1', subject: '')],
    );
  });

  test('no argument is no forward', () {
    expect(ComposeWindowApp.forwardedMessagesFromJson(null), isEmpty);
  });
}
