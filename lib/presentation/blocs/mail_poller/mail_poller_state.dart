import 'package:equatable/equatable.dart';

class MailPollerState extends Equatable {
  const MailPollerState({
    required this.accountsWithNewMail,
    required this.pollIntervalSeconds,
    this.pollGeneration = 0,
  });

  final Set<String> accountsWithNewMail;
  final int pollIntervalSeconds;

  /// Incremented each time the active account's inbox has new changes detected
  /// by a delta sync, signalling the email list should be refreshed.
  final int pollGeneration;

  bool get isPollingEnabled => pollIntervalSeconds > 0;

  MailPollerState copyWith({
    Set<String>? accountsWithNewMail,
    int? pollIntervalSeconds,
    int? pollGeneration,
  }) {
    return MailPollerState(
      accountsWithNewMail: accountsWithNewMail ?? this.accountsWithNewMail,
      pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
      pollGeneration: pollGeneration ?? this.pollGeneration,
    );
  }

  @override
  List<Object?> get props => [accountsWithNewMail, pollIntervalSeconds, pollGeneration];
}
