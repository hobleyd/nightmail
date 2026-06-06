import 'package:equatable/equatable.dart';

class EmailAddress extends Equatable {
  const EmailAddress({required this.address, this.name});

  final String address;
  final String? name;

  String get displayName => name?.isNotEmpty == true ? name! : address;

  @override
  List<Object?> get props => [address, name];
}
