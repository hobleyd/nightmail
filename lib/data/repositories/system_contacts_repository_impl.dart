import 'package:flutter_contacts/flutter_contacts.dart';

import '../../domain/entities/contact_suggestion.dart';
import '../../domain/repositories/system_contacts_repository.dart';

class SystemContactsRepositoryImpl implements SystemContactsRepository {
  List<Contact>? _cache;

  @override
  Future<List<ContactSuggestion>> search(String query) async {
    if (_cache == null) {
      final status = await FlutterContacts.permissions.request(PermissionType.read);
      if (status != PermissionStatus.granted &&
          status != PermissionStatus.limited) {
        return [];
      }
      _cache = await FlutterContacts.getAll(
        properties: {ContactProperty.email, ContactProperty.name},
      );
    }

    final q = query.toLowerCase();
    final results = <ContactSuggestion>[];

    for (final contact in _cache!) {
      for (final email in contact.emails) {
        if (email.address.isNotEmpty &&
            (email.address.toLowerCase().contains(q) ||
                (contact.displayName ?? '').toLowerCase().contains(q))) {
          results.add(ContactSuggestion(
            address: email.address,
            name: contact.displayName?.isEmpty ?? true
                ? null
                : contact.displayName,
          ));
        }
      }
    }
    return results;
  }
}
