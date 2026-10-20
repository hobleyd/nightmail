import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/room_location.dart';

void main() {
  const room = 'htw.com.au_3336@resource.calendar.google.com';

  group('stripRoomNames', () {
    test('drops a room named by Google\'s own name for it', () {
      // What a dragged meeting carries: Google's generated name, not the
      // directory's — so the save, which names the room again, must not see it.
      expect(
        stripRoomNames('BNE-3-Boardroom (10), Google Meet',
            ['BNE-3-Boardroom (10)', room]),
        'Google Meet',
      );
    });

    test('drops a room left in the location by its address', () {
      expect(stripRoomNames('$room; Level 3', [null, room]), 'Level 3');
    });

    test('matches case-insensitively and ignores blank labels', () {
      expect(stripRoomNames('boardroom, Level 3', ['Boardroom', '', null]),
          'Level 3');
    });

    test('returns a location with nothing to strip exactly as written', () {
      expect(stripRoomNames('Level 3; kitchen', ['Boardroom']),
          'Level 3; kitchen');
    });

    test('a location that was only the room becomes empty', () {
      expect(stripRoomNames('Boardroom', ['Boardroom']), '');
    });
  });
}
