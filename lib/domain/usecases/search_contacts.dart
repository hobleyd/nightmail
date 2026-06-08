import '../entities/contact_suggestion.dart';
import '../repositories/sender_repository.dart';
import '../repositories/system_contacts_repository.dart';

class SearchContacts {
  const SearchContacts({
    required this.senderRepository,
    required this.systemContactsRepository,
  });

  final SenderRepository senderRepository;
  final SystemContactsRepository systemContactsRepository;

  Future<List<ContactSuggestion>> call({
    required String query,
    required String accountId,
  }) async {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return [];

    final seen = <String>{};
    final results = <ContactSuggestion>[];

    // Known senders first — already emailed them, highest relevance
    try {
      final senders = await senderRepository.getSendersForAccount(accountId);
      for (final s in senders) {
        if (s.address.toLowerCase().contains(q) ||
            s.name.toLowerCase().contains(q)) {
          if (seen.add(s.address.toLowerCase())) {
            results.add(ContactSuggestion(
              address: s.address,
              name: s.name.isEmpty ? null : s.name,
            ));
          }
        }
      }
    } catch (_) {}

    // System contacts
    try {
      final contacts = await systemContactsRepository.search(q);
      for (final c in contacts) {
        if (seen.add(c.address.toLowerCase())) {
          results.add(c);
        }
      }
    } catch (_) {}

    return results.take(8).toList();
  }
}
