import '../entities/contact_suggestion.dart';

abstract interface class DirectoryContactsRepository {
  Future<List<ContactSuggestion>> search(String query);
}
