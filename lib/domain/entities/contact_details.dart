import 'dart:typed_data';

class ContactDetails {
  const ContactDetails({
    required this.address,
    this.name,
    this.jobTitle,
    this.department,
    this.companyName,
    this.officeLocation,
    this.phoneNumbers = const [],
    this.photoUrl,
    this.photoBytes,
  });

  final String address;
  final String? name;
  final String? jobTitle;
  final String? department;
  final String? companyName;
  final String? officeLocation;
  final List<String> phoneNumbers;
  final String? photoUrl;
  final Uint8List? photoBytes;

  bool get hasAnyDetail =>
      (jobTitle?.isNotEmpty ?? false) ||
      (department?.isNotEmpty ?? false) ||
      (companyName?.isNotEmpty ?? false) ||
      (officeLocation?.isNotEmpty ?? false) ||
      phoneNumbers.isNotEmpty;

  ContactDetails copyWith({String? photoUrl, Uint8List? photoBytes}) {
    return ContactDetails(
      address: address,
      name: name,
      jobTitle: jobTitle,
      department: department,
      companyName: companyName,
      officeLocation: officeLocation,
      phoneNumbers: phoneNumbers,
      photoUrl: photoUrl ?? this.photoUrl,
      photoBytes: photoBytes ?? this.photoBytes,
    );
  }
}
