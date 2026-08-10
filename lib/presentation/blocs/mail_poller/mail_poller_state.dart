import 'package:equatable/equatable.dart';

class MailPollerState extends Equatable {
  const MailPollerState({
    required this.accountsWithNewMail,
    required this.pollIntervalSeconds,
    this.pollGeneration = 0,
    this.accountsNeedingReauth = const {},
    this.lastPollAt,
    this.lastPollErrors = const {},
    this.syncedFolderIds = const {},
  });

  final Set<String> accountsWithNewMail;
  final int pollIntervalSeconds;

  /// Incremented each time a poll cycle found changes in a folder it syncs for
  /// the active account, signalling the email list should be refreshed.
  final int pollGeneration;

  /// Accounts whose last poll failed with an auth error (expired/revoked
  /// token). Polling keeps retrying but stops updating that account's counts
  /// until the user re-authenticates.
  final Set<String> accountsNeedingReauth;

  /// When the last cycle *finished*, successfully or not.
  ///
  /// The whole point is to be able to tell "polling is running and finding
  /// nothing" apart from "polling stopped". A poller that has silently wedged
  /// — a hung request, a connectivity probe stuck on offline, a delta token the
  /// server rejects — used to look exactly like a quiet mailbox.
  final DateTime? lastPollAt;

  /// Per-account failure from the last cycle that touched it, keyed by account
  /// id. Absent means that account's last cycle succeeded.
  ///
  /// Every one of these was swallowed by a bare `catch (_)` before: the account
  /// wrote no cache, bumped no generation, raised no banner and logged nothing,
  /// so a *deterministic* failure (a stored delta link the server answers 400,
  /// a delta response with no delta link) persisted across restarts with no
  /// symptom other than mail never updating.
  final Map<String, String> lastPollErrors;

  /// The folder ids the last cycle actually synced and wrote cache for, on the
  /// active account.
  ///
  /// The list repaints from the cache of the folder *on screen*, so a repaint is
  /// only valid for a folder in this set; anything else has to be refetched over
  /// the network. Before this existed the poller only ever wrote the Inbox and
  /// the repaint re-read whatever folder was showing — so a machine parked on
  /// Archive or a label re-read its own untouched cache and never changed.
  final Set<String> syncedFolderIds;

  bool get isPollingEnabled => pollIntervalSeconds > 0;

  /// Whether the last cycle reported a problem for any account.
  bool get hasPollErrors => lastPollErrors.isNotEmpty;

  MailPollerState copyWith({
    Set<String>? accountsWithNewMail,
    int? pollIntervalSeconds,
    int? pollGeneration,
    Set<String>? accountsNeedingReauth,
    DateTime? lastPollAt,
    Map<String, String>? lastPollErrors,
    Set<String>? syncedFolderIds,
  }) {
    return MailPollerState(
      accountsWithNewMail: accountsWithNewMail ?? this.accountsWithNewMail,
      pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
      pollGeneration: pollGeneration ?? this.pollGeneration,
      accountsNeedingReauth:
          accountsNeedingReauth ?? this.accountsNeedingReauth,
      lastPollAt: lastPollAt ?? this.lastPollAt,
      lastPollErrors: lastPollErrors ?? this.lastPollErrors,
      syncedFolderIds: syncedFolderIds ?? this.syncedFolderIds,
    );
  }

  // Every field the poller mutates has to be in here. Bloc's emit drops a state
  // that compares equal to the current one, so a field left out of props is a
  // field whose change is silently never delivered.
  @override
  List<Object?> get props => [
        accountsWithNewMail,
        pollIntervalSeconds,
        pollGeneration,
        accountsNeedingReauth,
        lastPollAt,
        lastPollErrors,
        syncedFolderIds,
      ];
}
