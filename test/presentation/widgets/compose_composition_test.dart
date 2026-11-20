import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/compose_composition.dart';

void main() {
  const sig = 'Regards,\nDavid Hobley';

  group('PlainComposition', () {
    test('a reply as built: text above, signature and quote kept', () {
      const body = 'Thanks Bob.\nSee you then.\n\n$sig\n\n---\n\n'
          'On 1 Jan 2026, Bob <b@x.com> wrote:\n\nshall we?';
      final c = PlainComposition.locate(body, sig);

      expect(c.foundBoundary, isTrue);
      expect(c.foundSignature, isTrue);
      expect(c.text(body), 'Thanks Bob.\nSee you then.');
      expect(
        c.replace(body, 'Yes, Friday.'),
        'Yes, Friday.\n\n$sig\n\n---\n\n'
        'On 1 Jan 2026, Bob <b@x.com> wrote:\n\nshall we?',
      );
    });

    test('a forward stops at the forwarded-message separator', () {
      const body = 'FYI\n\n---------- Forwarded message ---------\n'
          'From: Bob\n\nbody';
      final c = PlainComposition.locate(body, '');

      expect(c.foundBoundary, isTrue);
      expect(c.foundSignature, isFalse);
      expect(c.text(body), 'FYI');
      expect(c.replace(body, 'See below.'),
          'See below.\n\n---------- Forwarded message ---------\nFrom: Bob\n\nbody');
    });

    test('a ">"-quoted line is a boundary too', () {
      const body = 'Agreed.\n> earlier text\n> more';
      final c = PlainComposition.locate(body, sig);
      expect(c.text(body), 'Agreed.');
      expect(c.foundSignature, isFalse);
    });

    test('a new message with no quote is all composition, less the signature',
        () {
      const body = '\n\nHello there\n\n$sig';
      final c = PlainComposition.locate(body, sig);

      expect(c.foundBoundary, isFalse);
      expect(c.foundSignature, isTrue);
      expect(c.text(body), 'Hello there');
      expect(c.replace(body, 'Hi'), 'Hi\n\n$sig');
    });

    test('an edited signature is part of the composition', () {
      const body = 'Hello\n\nRegards,\nDave\n\n---\n\nOn x, y wrote:\nq';
      final c = PlainComposition.locate(body, sig);
      expect(c.foundSignature, isFalse);
      expect(c.text(body), 'Hello\n\nRegards,\nDave');
    });

    test('an empty body replaced is just the replacement', () {
      final c = PlainComposition.locate('', sig);
      expect(c.replace('', 'New text\n'), 'New text');
    });
  });
}
