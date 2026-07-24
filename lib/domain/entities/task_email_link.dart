/// Helpers for linking a source email to a task via its notes.
///
/// Google Tasks (and, as a portable fallback, Microsoft To Do) have no
/// attachment API, so the source email is referenced by embedding a marker
/// line in the task's notes: `nightmail://email/<emailId>`. The app renders
/// that marker as a tappable "View source email" link that opens the message
/// in the reading pane; other clients (Google's own Tasks UI) just show it as
/// inert text.
abstract final class TaskEmailLink {
  static const _prefix = 'nightmail://email/';

  /// The marker line stored in a task's notes for [emailId].
  static String marker(String emailId) => '$_prefix$emailId';

  /// Extracts the linked email id from [notes], or null if there is none.
  static String? emailIdFrom(String? notes) {
    if (notes == null) return null;
    final match = RegExp(r'nightmail://email/(\S+)').firstMatch(notes);
    return match?.group(1);
  }

  /// [notes] with any marker line(s) removed and trimmed. Returns null when
  /// nothing human-readable remains, so callers can treat "link only" notes
  /// as having no visible body.
  static String? visibleNotes(String? notes) {
    if (notes == null) return null;
    final cleaned = notes
        .split('\n')
        .where((line) => !line.contains(_prefix))
        .join('\n')
        .trim();
    return cleaned.isEmpty ? null : cleaned;
  }
}
