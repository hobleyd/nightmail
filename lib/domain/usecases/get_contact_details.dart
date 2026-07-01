import '../entities/contact_details.dart';
import '../repositories/contact_details_repository.dart';

class GetContactDetails {
  const GetContactDetails(this.repository);

  final ContactDetailsRepository repository;

  Future<ContactDetails?> call({
    required String address,
    required String accountId,
  }) {
    return repository.getContactDetails(address: address, accountId: accountId);
  }
}
