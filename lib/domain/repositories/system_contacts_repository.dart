import '../entities/contact_suggestion.dart';

/// Where the OS stands on letting NightMail read the address book.
enum ContactsPermission {
  granted,

  /// Refused without the decision being recorded: the request was answered
  /// "no" with no dialog shown, which is what macOS does when its record of
  /// the app no longer matches the installed one.
  denied,

  /// Recorded as refused (or restricted by policy) in System Settings.
  permanentlyDenied,

  /// No contacts integration on this platform.
  unsupported,
}

abstract interface class SystemContactsRepository {
  /// Requests contacts permission. Safe to call concurrently — the underlying
  /// request runs only once.
  Future<void> warmUp();

  /// Whether the OS exposes an address book to this app at all. False on
  /// platforms with no contacts integration and when permission was refused,
  /// which lets the sync service skip the source instead of recording a
  /// failure for something that can never succeed.
  Future<bool> isAvailable();

  /// The answer [warmUp] got, requesting it first if it has not run yet.
  Future<ContactsPermission> permission();

  /// Every contact in the OS address book, for the daily cache refresh.
  /// Returns an empty list when unavailable rather than throwing.
  Future<List<ContactSuggestion>> fetchAll();

  /// Live per-keystroke search. Only used as a fallback before the cache has
  /// been populated for an account, or when the compose window has no account
  /// selected — the typeahead otherwise reads the cache.
  Future<List<ContactSuggestion>> search(String query);
}
