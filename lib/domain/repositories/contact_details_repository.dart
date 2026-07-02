import '../entities/contact_details.dart';

abstract interface class ContactDetailsRepository {
  Future<ContactDetails?> getContactDetails({
    required String address,
    required String accountId,
  });
}
