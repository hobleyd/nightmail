/// Where the user's own writing ends in a plain-text compose body: above the
/// quoted reply or forwarded message, and above the signature when it is
/// there unedited.
///
/// The plain-text twin of `getComposition`/`replaceComposition` in
/// `assets/editor/editor.html`, which do the same for an HTML body — the same
/// separator lines, the same rule that a signature counts only if its text
/// matches. See "The AI Pane Edits Only the Composition" in
/// `docs/claude/webviews.md`.
class PlainComposition {
  const PlainComposition._({
    required this.end,
    required this.foundBoundary,
    required this.foundSignature,
  });

  /// The composition is `body.substring(0, end)`; the signature and/or quote
  /// follow from here.
  final int end;

  final bool foundBoundary;
  final bool foundSignature;

  static final RegExp _quoteLine = RegExp(
      r'^(-+ ?(Original Message|Forwarded message) ?-+|-{3}|On .{1,300} wrote:)$');

  static PlainComposition locate(String body, String signatureText) {
    var boundary = -1;
    var offset = 0;
    for (final line in body.split('\n')) {
      final t = line.trim();
      if (t.startsWith('>') || _quoteLine.hasMatch(t)) {
        boundary = offset;
        break;
      }
      offset += line.length + 1;
    }
    final regionEnd = boundary == -1 ? body.length : boundary;
    final region = body.substring(0, regionEnd).trimRight();

    final sig = signatureText.trim();
    if (sig.isNotEmpty && region.endsWith(sig)) {
      return PlainComposition._(
        end: region.length - sig.length,
        foundBoundary: boundary != -1,
        foundSignature: true,
      );
    }
    return PlainComposition._(
      end: boundary == -1 ? body.length : boundary,
      foundBoundary: boundary != -1,
      foundSignature: false,
    );
  }

  /// What the user wrote, trimmed.
  String text(String body) => body.substring(0, end).trim();

  /// [body] with the composition replaced by [replacement], and a blank line
  /// between it and whatever follows.
  String replace(String body, String replacement) {
    final rest = body.substring(end).replaceFirst(RegExp(r'^\s*'), '');
    final head = replacement.trim();
    if (rest.isEmpty) return head;
    return '$head\n\n$rest';
  }
}
