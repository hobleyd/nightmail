class ContactSuggestion {
  const ContactSuggestion({required this.address, this.name});

  final String address;
  final String? name;

  String get displayText {
    final n = name;
    if (n != null && n.isNotEmpty) return '$n <$address>';
    return address;
  }
}
