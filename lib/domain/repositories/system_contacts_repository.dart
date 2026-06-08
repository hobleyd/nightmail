import '../entities/contact_suggestion.dart';

abstract interface class SystemContactsRepository {
  Future<List<ContactSuggestion>> search(String query);
}
