import '../../domain/entities/email_address.dart';

class EmailAddressModel extends EmailAddress {
  const EmailAddressModel({required super.address, super.name});

  factory EmailAddressModel.fromJson(Map<String, dynamic> json) {
    final emailAddress = json['emailAddress'] as Map<String, dynamic>? ?? json;
    return EmailAddressModel(
      address: emailAddress['address'] as String? ?? '',
      name: emailAddress['name'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'emailAddress': {
          'address': address,
          if (name != null) 'name': name,
        },
      };

  factory EmailAddressModel.fromEntity(EmailAddress entity) {
    return EmailAddressModel(address: entity.address, name: entity.name);
  }
}
