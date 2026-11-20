import '../../../domain/entities/email.dart';
import '../../models/email_model.dart';

/// New Inbox mail as [LocalRuleMailbox.fetchInboxArrivals] found it.
class InboxArrivals {
  const InboxArrivals({
    required this.uidValidity,
    required this.uidNext,
    required this.keywordsAllowed,
    required this.messages,
    this.modSequences = const {},
    this.autoSubmitted = const {},
  });

  /// The Inbox's UIDVALIDITY when it was selected. A change means the server
  /// rebuilt the mailbox and every remembered UID names a different message.
  final int? uidValidity;

  /// UIDNEXT as of the same SELECT: every message below it existed then, so
  /// one not in [messages] was already claimed elsewhere or deleted.
  final int? uidNext;

  /// The Inbox accepts custom keywords (`\*` in PERMANENTFLAGS), so a claim
  /// can be stored on the message itself and seen by other devices.
  final bool keywordsAllowed;

  /// Envelope and structure only (no body), oldest first.
  final List<EmailModel> messages;

  /// Each message's MODSEQ, where the server has CONDSTORE — what makes a
  /// claim a compare-and-set ([LocalRuleMailbox.claim]).
  final Map<String, int> modSequences;

  /// Ids of messages whose `Auto-Submitted` header is anything but `no`
  /// (RFC 3834): automatic replies, bounces, and forwards — another rule's
  /// included. A rule never forwards one, which is what breaks a loop
  /// between two accounts forwarding to each other.
  final Set<String> autoSubmitted;

  /// The highest UID that existed at the SELECT, or null if the server did
  /// not say.
  int? get lastExistingUid => uidNext == null ? null : uidNext! - 1;
}

/// What NightMail's own IMAP rule runner needs from the mailbox.
///
/// Its own interface, implemented by `ImapDatasourceImpl`, so the runner can
/// be tested against a fake and the IMAP commands against the scripted
/// server in `imap_test_harness.dart`.
abstract interface class LocalRuleMailbox {
  /// Inbox messages with a UID above [afterUid], at most [limit], oldest
  /// first, leaving out any carrying [excludeKeyword] when the server keeps
  /// keywords. [afterUid] null fetches no messages and only reports the
  /// Inbox's UIDVALIDITY and UIDNEXT — how the runner starts from "now".
  Future<InboxArrivals> fetchInboxArrivals({
    required int? afterUid,
    required int limit,
    String? excludeKeyword,
  });

  /// The full message, without setting `\Seen` — a body condition must not
  /// mark every new message read.
  Future<EmailModel> peekEmail(String id);

  /// Adds [flags] (system flags or keywords) to the message.
  Future<void> addFlags(String id, List<String> flags);

  /// Stores [keyword] on the message as this device's claim to run the rules
  /// on it. With [unchangedSince] (its MODSEQ) the store is conditional, and
  /// false means another device changed the message first — claimed it, most
  /// likely — so this one must leave it. Without CONDSTORE it always succeeds
  /// and two devices polling at the same moment can both act.
  Future<bool> claim(String id, String keyword, {int? unchangedSince});

  /// Moves the message to Trash, and refuses — rather than expunging, which
  /// is what [EmailRemoteDatasource.deleteEmail] falls back to — when the
  /// server has no Trash. A rule deletes without anyone confirming it.
  Future<void> trashEmail(String id);

  Future<void> copyEmail(String id, String destinationFolderId);

  Future<String?> moveEmail(String id, String destinationFolderId);

  Future<EmailModel> updateEmailReadStatus({
    required String id,
    required bool isRead,
  });

  /// Forwards the message with its attachments, marked
  /// `Auto-Submitted: auto-forwarded` so no rule — here or on the receiving
  /// side — forwards it again. [comment] is the whole body, quoted original
  /// included.
  Future<void> forwardForRule({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
    required EmailBodyType bodyType,
  });
}
