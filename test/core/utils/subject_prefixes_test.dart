import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/subject_prefixes.dart';

void main() {
  group('replySubjectFor', () {
    test('replaces a forward prefix rather than stacking on it', () {
      expect(replySubjectFor('Fwd: Budget'), 'Re: Budget');
      expect(replySubjectFor('FW: Budget'), 'Re: Budget');
    });

    test('collapses a stack of mixed prefixes', () {
      expect(replySubjectFor('Re: Fwd: RE: FW: Budget'), 'Re: Budget');
      expect(replySubjectFor('Re[2]: Budget'), 'Re: Budget');
      expect(replySubjectFor('AW: WG: Budget'), 'Re: Budget');
    });

    test('leaves a bare subject with a single prefix', () {
      expect(replySubjectFor('Budget'), 'Re: Budget');
      expect(replySubjectFor('  Budget  '), 'Re: Budget');
    });

    test('does not eat a word that merely starts with a prefix', () {
      expect(replySubjectFor('Reorganisation'), 'Re: Reorganisation');
      expect(replySubjectFor('Fwd budget'), 'Re: Fwd budget');
    });

    test('gives a bare prefix for an empty or prefix-only subject', () {
      expect(replySubjectFor(''), 'Re:');
      expect(replySubjectFor('Re:'), 'Re:');
      expect(replySubjectFor('Fwd: '), 'Re:');
    });
  });

  group('forwardSubjectFor', () {
    test('replaces a reply prefix rather than stacking on it', () {
      expect(forwardSubjectFor('Re: Budget'), 'Fwd: Budget');
      expect(forwardSubjectFor('Re: RE: Budget'), 'Fwd: Budget');
    });

    test('normalises an existing forward prefix', () {
      expect(forwardSubjectFor('FW: Budget'), 'Fwd: Budget');
      expect(forwardSubjectFor('Fwd: Budget'), 'Fwd: Budget');
    });

    test('gives a bare prefix for an empty subject', () {
      expect(forwardSubjectFor(''), 'Fwd:');
    });
  });

  group('stripSubjectPrefixes', () {
    test('keeps a subject that is only a prefix', () {
      expect(stripSubjectPrefixes('Re:'), 'Re:');
    });
  });
}
