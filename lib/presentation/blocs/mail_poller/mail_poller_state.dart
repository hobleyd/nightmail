import 'package:equatable/equatable.dart';

class MailPollerState extends Equatable {
  const MailPollerState({
    required this.accountsWithNewMail,
    required this.pollIntervalSeconds,
    this.pollGeneration = 0,
    this.accountsNeedingReauth = const {},
  });

  final Set<String> accountsWithNewMail;
  final int pollIntervalSeconds;

  /// Incremented each time the active account's inbox has new changes detected
  /// by a delta sync, signalling the email list should be refreshed.
  final int pollGeneration;

  /// Accounts whose last poll failed with an auth error (expired/revoked
  /// token). Polling keeps retrying but stops updating that account's counts
  /// until the user re-authenticates.
  final Set<String> accountsNeedingReauth;

  bool get isPollingEnabled => pollIntervalSeconds > 0;

  MailPollerState copyWith({
    Set<String>? accountsWithNewMail,
    int? pollIntervalSeconds,
    int? pollGeneration,
    Set<String>? accountsNeedingReauth,
  }) {
    return MailPollerState(
      accountsWithNewMail: accountsWithNewMail ?? this.accountsWithNewMail,
      pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
      pollGeneration: pollGeneration ?? this.pollGeneration,
      accountsNeedingReauth:
          accountsNeedingReauth ?? this.accountsNeedingReauth,
    );
  }

  @override
  List<Object?> get props => [
        accountsWithNewMail,
        pollIntervalSeconds,
        pollGeneration,
        accountsNeedingReauth,
      ];
}
