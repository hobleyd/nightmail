import '../entities/contact_suggestion.dart';

abstract interface class SystemContactsRepository {
  /// Requests contacts permission and pre-loads the cache.
  /// Safe to call concurrently — the underlying load runs only once.
  Future<void> warmUp();

  Future<List<ContactSuggestion>> search(String query);
}
