import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/presentation/widgets/contacts_access_notice.dart';

void main() {
  group('contactsAccessAction', () {
    ContactsAccessAction act(bool before, ContactsPermission now) =>
        contactsAccessAction(grantedBefore: before, permission: now);

    test('the first grant is remembered, later ones change nothing', () {
      expect(act(false, ContactsPermission.granted),
          ContactsAccessAction.remember);
      expect(act(true, ContactsPermission.granted), ContactsAccessAction.none);
    });

    test('losing a grant warns, however macOS refused', () {
      // `denied` is what every launch after the 1.47.3 install answered.
      expect(act(true, ContactsPermission.denied), ContactsAccessAction.warn);
      expect(act(true, ContactsPermission.permanentlyDenied),
          ContactsAccessAction.warn);
    });

    test('a reader who never granted access is never nagged', () {
      expect(act(false, ContactsPermission.denied), ContactsAccessAction.none);
      expect(act(false, ContactsPermission.permanentlyDenied),
          ContactsAccessAction.none);
    });

    test('a platform without an address book says nothing', () {
      expect(act(true, ContactsPermission.unsupported),
          ContactsAccessAction.none);
    });
  });
}
