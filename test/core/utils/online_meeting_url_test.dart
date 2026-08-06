import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/online_meeting_url.dart';

/// This predicate decides whether a location string is a *place* or a derived
/// join link. Getting it wrong in either direction is destructive: a false
/// negative prefixes a room name onto a join URL and takes the Join Meeting
/// affordance away; a false positive drops the room name from a real location.
void main() {
  group('recognised as a join link', () {
    const urls = [
      'https://meet.google.com/abc-defg-hij',
      'https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=x',
      'https://teams.live.com/meet/9312345',
      'https://acme.zoom.us/j/1234567890',
      'https://zoom.us/j/1234567890',
    ];
    for (final url in urls) {
      test(url, () => expect(isOnlineMeetingUrl(url), isTrue));
    }

    test('tolerates surrounding whitespace', () {
      expect(isOnlineMeetingUrl('  https://meet.google.com/abc  '), isTrue);
    });

    test('is case-insensitive on the host', () {
      expect(isOnlineMeetingUrl('https://MEET.GOOGLE.COM/abc'), isTrue);
    });
  });

  group('treated as an ordinary location', () {
    const places = [
      'Level 3 kitchen',
      'Boardroom',
      '',
      // The placeholders the form drops in when the online-meeting toggle is
      // switched on. The real link only exists after the provider creates it,
      // so these must still behave as text and let a room name itself.
      'Google Meet',
      'Microsoft Teams Meeting',
      // A link, but not a meeting one — no reason to protect it.
      'https://maps.google.com/?q=head+office',
      'https://contoso.sharepoint.com/sites/team',
    ];
    for (final place in places) {
      test('"$place"', () => expect(isOnlineMeetingUrl(place), isFalse));
    }

    test('null', () => expect(isOnlineMeetingUrl(null), isFalse));

    test('a Teams tenant page that is not a meetup-join link', () {
      expect(isOnlineMeetingUrl('https://teams.microsoft.com/_#/apps'), isFalse);
    });
  });

  group('splitMeetingLocation', () {
    const meet = 'https://meet.google.com/abc-defg-hij';

    test('keeps a place as the place and the provider link as the link', () {
      final r = splitMeetingLocation(
        rawLocation: 'Level 3 kitchen',
        onlineMeetingUrl: meet,
      );

      expect(r.location, 'Level 3 kitchen');
      expect(r.onlineMeetingUrl, meet);
    });

    test('a meeting can have both, which is the whole point', () {
      final r = splitMeetingLocation(
        rawLocation: 'Boardroom',
        onlineMeetingUrl: meet,
      );

      expect(r.location, 'Boardroom');
      expect(r.onlineMeetingUrl, meet);
    });

    test('recovers the link from a location left by the old single-field '
        'convention, and does not echo it back as a place', () {
      final r = splitMeetingLocation(rawLocation: meet);

      expect(r.onlineMeetingUrl, meet);
      expect(r.location, isNull);
    });

    test('the provider field wins over a link sitting in the location', () {
      const authoritative = 'https://teams.microsoft.com/l/meetup-join/19%3ax/0';
      final r = splitMeetingLocation(
        rawLocation: meet,
        onlineMeetingUrl: authoritative,
      );

      expect(r.onlineMeetingUrl, authoritative);
      expect(r.location, isNull);
    });

    test('scrapes the description only as a last resort', () {
      final r = splitMeetingLocation(
        rawLocation: 'Level 3',
        description: 'Dial in at $meet if you cannot make it',
      );

      expect(r.location, 'Level 3');
      expect(r.onlineMeetingUrl, meet);
    });

    test('a description link does not override the provider field', () {
      final r = splitMeetingLocation(
        onlineMeetingUrl: meet,
        description: 'old link: https://meet.google.com/stale-link-xyz',
      );

      expect(r.onlineMeetingUrl, meet);
    });

    test('stops the scraped link at surrounding punctuation', () {
      final r = splitMeetingLocation(
        description: 'Join here: $meet (bring notes)',
      );

      expect(r.onlineMeetingUrl, meet);
    });

    test('an ordinary link in the description is not a meeting', () {
      final r = splitMeetingLocation(
        rawLocation: 'Level 3',
        description: 'Agenda at https://contoso.sharepoint.com/agenda',
      );

      expect(r.onlineMeetingUrl, isNull);
      expect(r.location, 'Level 3');
    });

    test('nothing at all', () {
      final r = splitMeetingLocation();

      expect(r.location, isNull);
      expect(r.onlineMeetingUrl, isNull);
    });

    test('blank strings are nothing, not empty values', () {
      final r = splitMeetingLocation(rawLocation: '   ', onlineMeetingUrl: '');

      expect(r.location, isNull);
      expect(r.onlineMeetingUrl, isNull);
    });
  });

  group('onlineMeetingPlatformName', () {
    test('Teams', () {
      expect(
        onlineMeetingPlatformName(
            'https://teams.microsoft.com/l/meetup-join/19%3ax/0'),
        'Microsoft Teams',
      );
    });
    test('Meet', () {
      expect(onlineMeetingPlatformName('https://meet.google.com/abc'),
          'Google Meet');
    });
    test('Zoom', () {
      expect(onlineMeetingPlatformName('https://acme.zoom.us/j/1'), 'Zoom');
    });
    test('anything else is still named, never shown as a raw URL', () {
      expect(onlineMeetingPlatformName('https://example.com/room/1'),
          'Online meeting');
    });
  });
}
