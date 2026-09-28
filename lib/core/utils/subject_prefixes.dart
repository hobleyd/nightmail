/// Reply/forward subject prefixes ("Re:", "Fwd:", "FW:", "Re[2]:", plus the
/// German/French forms) and the subjects a reply or forward should carry.
///
/// A reply to "Fwd: Budget" is "Re: Budget", not "Re: Fwd: Budget": the whole
/// prefix stack is replaced with the one for the new message, so a long
/// back-and-forth never accretes "Re: Re: Fwd: Re:". Mail clients
/// (Outlook, Apple Mail, Gmail) all do the same.
final RegExp _subjectPrefixes = RegExp(
  r'^(\s*(re|fwd?|aw|wg|tr)\s*(\[\d+\])?\s*:\s*)+',
  caseSensitive: false,
);

/// "Re: RE: Fwd: FW: Budget" → "Budget". A subject that is nothing but
/// prefixes is kept as it was rather than emptied.
String stripSubjectPrefixes(String subject) {
  final stripped = subject.replaceFirst(_subjectPrefixes, '').trim();
  return stripped.isNotEmpty ? stripped : subject.trim();
}

/// The subject for a reply to [originalSubject]: "Re: " plus the subject with
/// every existing reply/forward prefix removed. An empty original gives "Re:".
String replySubjectFor(String originalSubject) =>
    _prefixed('Re', originalSubject);

/// The subject for a forward of [originalSubject]: "Fwd: " plus the subject
/// with every existing reply/forward prefix removed.
String forwardSubjectFor(String originalSubject) =>
    _prefixed('Fwd', originalSubject);

String _prefixed(String prefix, String originalSubject) {
  final base = stripSubjectPrefixes(originalSubject);
  // A subject that was only prefixes strips to itself; it carries nothing
  // worth keeping under the new prefix.
  if (base.isEmpty ||
      _subjectPrefixes.matchAsPrefix(base)?.end == base.length) {
    return '$prefix:';
  }
  return '$prefix: $base';
}
