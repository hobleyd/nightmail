import 'package:equatable/equatable.dart';

class MailPollerState extends Equatable {
  const MailPollerState({
    required this.accountsWithNewMail,
    required this.pollIntervalSeconds,
  });

  final Set<String> accountsWithNewMail;
  final int pollIntervalSeconds;

  bool get isPollingEnabled => pollIntervalSeconds > 0;

  MailPollerState copyWith({
    Set<String>? accountsWithNewMail,
    int? pollIntervalSeconds,
  }) {
    return MailPollerState(
      accountsWithNewMail: accountsWithNewMail ?? this.accountsWithNewMail,
      pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
    );
  }

  @override
  List<Object?> get props => [accountsWithNewMail, pollIntervalSeconds];
}
