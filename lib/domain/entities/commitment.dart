import 'package:equatable/equatable.dart';

import 'email_address.dart';

/// Which side of the ledger a commitment sits on.
enum CommitmentKind {
  /// Something I promised someone, in a message I sent. "I owe".
  iOwe,

  /// Something I asked someone for, or they promised me, that has not come
  /// back yet. "They owe me" / "waiting on".
  theyOweMe,

  /// A received message that asks me to do, decide or reply to something —
  /// mail that deserves a decision, as opposed to the mail that does not.
  needsAction,
}

enum CommitmentStatus { open, done, dismissed }

/// How soon, as the model read it off the message.
///
/// Coarse on purpose: a System One model picks one of a fixed set of options,
/// it cannot write a date. Judged relative to when the message was written,
/// so [Commitment.isOverdueAt] combines it with [Commitment.emailDate].
enum CommitmentDue { today, thisWeek, later, none }

/// One tracked obligation, lifted out of a single email by a System One
/// (typed decision) model — see `DetectCommitments`.
///
/// The message is the commitment's evidence, so a commitment is keyed by
/// `(kind, emailId)`: one sent message can create both an *I owe* ("I'll send
/// the numbers") and a *they owe me* ("…once you confirm the scope"), and a
/// re-scan can never duplicate either.
class Commitment extends Equatable {
  const Commitment({
    required this.id,
    required this.accountId,
    required this.emailId,
    this.conversationId,
    required this.kind,
    required this.status,
    required this.counterpart,
    required this.subject,
    required this.snippet,
    required this.due,
    required this.urgency,
    required this.confidence,
    required this.emailDate,
    required this.detectedAt,
    this.resolvedAt,
    this.scheduledEventId,
    this.scheduledStart,
    this.scheduledEnd,
    this.estimatedMinutes,
  });

  /// `'<kind>:<emailId>'`.
  static String idFor(CommitmentKind kind, String emailId) =>
      '${kind.name}:$emailId';

  final String id;
  final String accountId;
  final String emailId;

  /// The thread the message belongs to, when the provider reports one. Drives
  /// the automatic resolution rules (a reply from the counterpart closes a
  /// *they owe me*; my own reply closes a *needs action*).
  final String? conversationId;

  final CommitmentKind kind;
  final CommitmentStatus status;

  /// The other party: who I owe, who owes me, or who is asking.
  final EmailAddress counterpart;

  final String subject;

  /// The opening of the message text, as a reminder of what was said.
  final String snippet;

  final CommitmentDue due;

  /// The model's urgency reading on a three-level rubric, rounded: 0 = no
  /// time pressure, 1 = needs attention soon, 2 = blocking / hard deadline.
  final int urgency;

  /// The model's confidence in the detection, 0–1.
  final double confidence;

  /// When the message was sent (outgoing) or received (incoming).
  final DateTime emailDate;

  final DateTime detectedAt;
  final DateTime? resolvedAt;

  /// The calendar event that blocks time for this commitment, once the user
  /// has scheduled it — see `SuggestTimeBlock` and `CommitmentsCubit.schedule`.
  /// Rescheduling moves that event rather than adding another.
  final String? scheduledEventId;
  final DateTime? scheduledStart;
  final DateTime? scheduledEnd;

  /// The model's reading of how much focused time the item needs, in
  /// minutes, on the rubric in `DetectCommitments.effortQuestion` (a quick
  /// reply up to half a day). Null until estimated — a row written before
  /// the estimate existed is filled in by the next scan.
  final int? estimatedMinutes;

  bool get isOpen => status == CommitmentStatus.open;

  bool get isScheduled => scheduledEventId != null && scheduledStart != null;

  /// The estimate as a duration, or null when there is none yet.
  Duration? get estimate =>
      estimatedMinutes == null ? null : Duration(minutes: estimatedMinutes!);

  /// The estimate, or [fallback] when the model has not given one — what
  /// every time-block default should size itself by.
  Duration estimateOr(Duration fallback) => estimate ?? fallback;

  /// How long this has been outstanding.
  Duration ageAt(DateTime now) => now.difference(emailDate);

  /// Whether the promised or requested item is past the horizon the model
  /// read: a *today* item from any earlier day, a *this week* item older than
  /// a week, a *later* item older than three weeks. A commitment with no
  /// deadline is never overdue — it can only be old.
  bool isOverdueAt(DateTime now) {
    if (!isOpen) return false;
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(emailDate.year, emailDate.month, emailDate.day);
    switch (due) {
      case CommitmentDue.today:
        return day.isBefore(today);
      case CommitmentDue.thisWeek:
        return today.difference(day).inDays > 7;
      case CommitmentDue.later:
        return today.difference(day).inDays > 21;
      case CommitmentDue.none:
        return false;
    }
  }

  /// Whether this belongs in a "today" view: due today, or already overdue.
  bool isDueTodayAt(DateTime now) =>
      isOpen && (due == CommitmentDue.today || isOverdueAt(now));

  Commitment copyWith({
    CommitmentStatus? status,
    DateTime? resolvedAt,
    bool clearResolvedAt = false,
    String? scheduledEventId,
    DateTime? scheduledStart,
    DateTime? scheduledEnd,
    bool clearSchedule = false,
    int? estimatedMinutes,
  }) {
    return Commitment(
      id: id,
      accountId: accountId,
      emailId: emailId,
      conversationId: conversationId,
      kind: kind,
      status: status ?? this.status,
      counterpart: counterpart,
      subject: subject,
      snippet: snippet,
      due: due,
      urgency: urgency,
      confidence: confidence,
      emailDate: emailDate,
      detectedAt: detectedAt,
      resolvedAt: clearResolvedAt ? null : (resolvedAt ?? this.resolvedAt),
      scheduledEventId:
          clearSchedule ? null : (scheduledEventId ?? this.scheduledEventId),
      scheduledStart:
          clearSchedule ? null : (scheduledStart ?? this.scheduledStart),
      scheduledEnd: clearSchedule ? null : (scheduledEnd ?? this.scheduledEnd),
      estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
    );
  }

  @override
  List<Object?> get props => [
        id,
        accountId,
        emailId,
        conversationId,
        kind,
        status,
        counterpart,
        subject,
        snippet,
        due,
        urgency,
        confidence,
        emailDate,
        detectedAt,
        resolvedAt,
        scheduledEventId,
        scheduledStart,
        scheduledEnd,
        estimatedMinutes,
      ];
}
