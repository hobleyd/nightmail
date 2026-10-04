import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/latest_reply.dart';
import '../../entities/ai/ai_capability.dart';
import '../../entities/ai/ai_decision.dart';
import '../../entities/commitment.dart';
import '../../entities/email.dart';
import '../../entities/email_address.dart';
import '../../repositories/ai/ai_inference_repository.dart';
import '../../repositories/ai/ai_settings_repository.dart';
import '../../repositories/commitment_repository.dart';

/// Lifts commitments out of an account's recent mail with the System One
/// model routed to [AiCapability.triage], and keeps the ledger current.
///
/// Each message not yet scanned is shown to the model once, as a structured
/// state (`direction`, `subject`, `from`, `to`, `body`) with typed questions:
///
/// * **sent mail** — *does the sender promise something?* → an *I owe*;
///   *does the sender ask for something?* → a *they owe me*; plus a coarse
///   *when is it due* choice and a three-level urgency score.
/// * **received mail** — *does this need the recipient to act or reply?* → a
///   *needs action*; *does the sender promise to deliver something?* → a
///   *they owe me*; a *bulk / newsletter / notification* check that vetoes
///   both; the same due and urgency questions.
///
/// Probabilities at or above [threshold] count. The body shown is the newest
/// reply only (`latestReplyText`), capped, so the quoted history below it
/// cannot be mistaken for the sender's own words — and so it fits the ~512
/// token window of the smaller local Laya checkpoints.
///
/// Every message is also asked **how much focused time** the item needs, on
/// the five-level [effortQuestion] rubric (a quick reply up to half a day),
/// and the level becomes [Commitment.estimatedMinutes] — what sizes its
/// time block, its share of the week-ahead demand and the assistant's
/// defaults. Open rows written before the question existed are filled in by
/// an **estimate pass** at the end of each run, [maxToEstimate] at a time,
/// from the cached message when it is still on hand and from the row's own
/// subject and excerpt otherwise.
///
/// After detection a **resolution pass** closes what the mail itself has
/// settled, with no model involved: a *they owe me* whose counterpart has
/// since replied in the same thread, and a *needs action* I have since
/// replied to. An *I owe* is only ever closed by hand — a later message of
/// mine in the thread may just as well be "still working on it".
///
/// Configuration problems surface as a `Left` ([NoProviderConfigured] when
/// Triage has no route). A provider failure *mid-scan* keeps what was
/// classified before it and reports the failure as [DetectCommitmentsResult.warning],
/// so a flaky local server costs a partial refresh, not the whole one.
///
/// Every model call is reported through [log] as one line — the model that
/// answered, the direction, the message id and the raw answers — so a miss
/// can be read off `diagnostics.log` rather than guessed at. Message text
/// never goes in the line.
class DetectCommitments {
  const DetectCommitments({
    required this.settingsRepository,
    required this.inferenceRepository,
    required this.commitmentRepository,
    this.log,
  });

  final AiSettingsRepository settingsRepository;
  final AiInferenceRepository inferenceRepository;
  final CommitmentRepository commitmentRepository;

  /// Receives one diagnostic line per model call (`debugPrint` in the app).
  final void Function(String line)? log;

  /// A noul answer at or above this counts as "yes".
  static const double threshold = 0.6;

  /// Longest body excerpt shown to the model, in characters.
  static const int maxBodyChars = 1500;

  /// Most open commitments given a missing estimate per run — each is one
  /// request, like a classification.
  static const int maxToEstimate = 20;

  Future<Either<Failure, DetectCommitmentsResult>> call(
    DetectCommitmentsParams params,
  ) async {
    final routingResult =
        await settingsRepository.getRouting(AiCapability.triage);
    if (routingResult.isLeft()) {
      return Left(routingResult.getLeft().toNullable()!);
    }
    final routing = routingResult.getOrElse((_) => null);
    if (routing == null) {
      return const Left(
        NoProviderConfigured(
          message: 'Route Triage to a System One provider (Jev or Laya-MLX) '
              'in Settings › AI to detect commitments.',
        ),
      );
    }

    final scannedResult = await commitmentRepository.getScannedEmailIds(
      accountId: params.accountId,
    );
    if (scannedResult.isLeft()) {
      return Left(scannedResult.getLeft().toNullable()!);
    }
    final scanned = scannedResult.getOrElse((_) => const {});

    // Candidates, newest first, so a capped scan spends its budget on the
    // mail most likely to still matter.
    final candidates = <_Candidate>[
      for (final e in params.sentEmails)
        if (!scanned.contains(e.id) && _isFromSelf(e, params.selfAddresses))
          _Candidate(e, outgoing: true),
      for (final e in params.inboxEmails)
        if (!scanned.contains(e.id) && !_isFromSelf(e, params.selfAddresses))
          _Candidate(e, outgoing: false),
    ]..sort((a, b) => _dateOf(b.email).compareTo(_dateOf(a.email)));
    final toClassify = candidates.take(params.maxToClassify).toList();
    final remaining = candidates.length - toClassify.length;

    final detected = <Commitment>[];
    final classifiedIds = <String>[];
    Failure? failure;
    String? model;

    for (final candidate in toClassify) {
      final request = AiDecisionRequest(
        providerId: routing.providerId,
        modelId: routing.modelId,
        state: stateFor(candidate.email, outgoing: candidate.outgoing),
        questions: candidate.outgoing ? sentQuestions : inboxQuestions,
      );
      final result = await inferenceRepository.decide(request);
      final stop = result.fold(
        (f) {
          failure = f;
          log?.call('[Commitments] ${routing.modelId} '
              '${candidate.outgoing ? 'out' : 'in'} '
              '${_shortId(candidate.email.id)}: failed: ${f.message}');
          return true;
        },
        (response) {
          model = response.model;
          final found = commitmentsFrom(
            candidate.email,
            response,
            outgoing: candidate.outgoing,
            accountId: params.accountId,
            selfAddresses: params.selfAddresses,
            now: params.now,
          );
          detected.addAll(found);
          classifiedIds.add(candidate.email.id);
          log?.call('[Commitments] ${response.model} '
              '${candidate.outgoing ? 'out' : 'in'} '
              '${_shortId(candidate.email.id)}: '
              '${describeAnswers(response, outgoing: candidate.outgoing)} → '
              '${found.isEmpty ? 'none' : found.map((c) => c.kind.name).join('+')}');
          return false;
        },
      );
      if (stop) break;
    }

    // Nothing got through and the very first call failed: that is the
    // failure, not a partial result.
    if (classifiedIds.isEmpty && failure != null) return Left(failure!);

    if (detected.isNotEmpty) {
      final saved = await commitmentRepository.saveCommitments(detected);
      if (saved.isLeft()) return Left(saved.getLeft().toNullable()!);
    }
    if (classifiedIds.isNotEmpty) {
      final marked = await commitmentRepository.markScanned(
        accountId: params.accountId,
        emailIds: classifiedIds,
        now: params.now,
      );
      if (marked.isLeft()) return Left(marked.getLeft().toNullable()!);
    }

    // Resolution pass over everything open, including what was just saved.
    final allResult = await commitmentRepository.getCommitments(
      accountId: params.accountId,
    );
    if (allResult.isLeft()) return Left(allResult.getLeft().toNullable()!);
    var all = allResult.getOrElse((_) => const []);

    final resolvedIds = <String>{};
    for (final c in all) {
      if (!c.isOpen) continue;
      if (isResolvedByMail(
        c,
        sentEmails: params.sentEmails,
        inboxEmails: params.inboxEmails,
        selfAddresses: params.selfAddresses,
      )) {
        final set = await commitmentRepository.setStatus(
          accountId: params.accountId,
          id: c.id,
          status: CommitmentStatus.done,
          now: params.now,
        );
        if (set.isRight()) resolvedIds.add(c.id);
      }
    }
    if (resolvedIds.isNotEmpty) {
      all = [
        for (final c in all)
          resolvedIds.contains(c.id)
              ? c.copyWith(
                  status: CommitmentStatus.done,
                  resolvedAt: params.now,
                )
              : c,
      ];
    }

    // Estimate pass: open rows that predate the effort question. Skipped
    // when the provider already failed this run — no point hammering it.
    final estimates = <String, int>{};
    if (failure == null) {
      final byId = {
        for (final e in params.sentEmails) e.id: e,
        for (final e in params.inboxEmails) e.id: e,
      };
      final pending = [
        for (final c in all)
          if (c.isOpen && c.estimatedMinutes == null) c,
      ].take(maxToEstimate);
      for (final c in pending) {
        final result = await inferenceRepository.decide(AiDecisionRequest(
          providerId: routing.providerId,
          modelId: routing.modelId,
          state: effortStateFor(c, byId[c.emailId], params.selfAddresses),
          questions: const {'effort': effortQuestion},
        ));
        final stop = result.fold(
          (f) {
            failure = f;
            log?.call('[Commitments] ${routing.modelId} estimate '
                '${_shortId(c.emailId)}: failed: ${f.message}');
            return true;
          },
          (response) {
            model = response.model;
            final minutes = minutesFrom(response.answers['effort']);
            if (minutes != null) estimates[c.id] = minutes;
            log?.call('[Commitments] ${response.model} estimate '
                '${_shortId(c.emailId)} ${c.kind.name}: '
                'effort=${_num(response.answers['effort'])} → '
                '${minutes == null ? 'none' : '$minutes min'}');
            return false;
          },
        );
        if (stop) break;
      }
      for (final entry in estimates.entries) {
        final set = await commitmentRepository.setEstimate(
          accountId: params.accountId,
          id: entry.key,
          minutes: entry.value,
        );
        if (set.isLeft()) estimates.remove(entry.key);
      }
      if (estimates.isNotEmpty) {
        all = [
          for (final c in all)
            estimates.containsKey(c.id)
                ? c.copyWith(estimatedMinutes: estimates[c.id])
                : c,
        ];
      }
    }

    return Right(
      DetectCommitmentsResult(
        commitments: all,
        classified: classifiedIds.length,
        remaining: remaining + (toClassify.length - classifiedIds.length),
        resolved: resolvedIds.length,
        estimated: estimates.length,
        model: model,
        warning: failure?.message,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Questions
  // ---------------------------------------------------------------------------

  static const AiDecisionQuestion _dueQuestion = AiDecisionQuestion.choice(
    instructions: 'By when is the promised or requested item due, according '
        'to the message in `body`?',
    options: {
      'today': 'today, tonight, or within 24 hours',
      'this_week': 'within the next few days or by the end of this week',
      'later': 'next week or later, or a specific date further out',
      'none': 'no deadline or timing is mentioned',
    },
  );

  static const AiDecisionQuestion _urgencyQuestion = AiDecisionQuestion.score(
    instructions: 'How urgent is the matter in `body`?',
    levels: [
      'no time pressure',
      'needs attention soon',
      'blocking issue or hard deadline',
    ],
  );

  /// How much focused time the item needs. A score rubric, lowest first;
  /// [effortMinutes] gives each level's length. Direction-neutral wording,
  /// since the same question sizes a promise I made and a request I got.
  static const AiDecisionQuestion effortQuestion = AiDecisionQuestion.score(
    instructions: 'How much focused working time would it take to fully deal '
        'with the request, promise or task in `body`?',
    levels: [
      'a few minutes — a quick reply, confirmation or forward',
      'about half an hour',
      'about an hour',
      'a couple of hours',
      'half a day or more',
    ],
  );

  /// Minutes per [effortQuestion] level.
  static const List<int> effortMinutes = [15, 30, 60, 120, 240];

  /// The estimate an effort answer stands for: its nearest rubric level's
  /// minutes, or null when the model gave no usable score.
  static int? minutesFrom(AiDecisionAnswer? answer) {
    final score = answer?.score;
    if (score == null || score.isNaN) return null;
    return effortMinutes[score.round().clamp(0, effortMinutes.length - 1)];
  }

  /// Asked about a message the account holder sent.
  static const Map<String, AiDecisionQuestion> sentQuestions = {
    'commits': AiDecisionQuestion.noul(
      instructions: 'Does the sender of `body` promise to do, send, deliver '
          'or get back to the recipient about something?',
      trueDescription: 'the sender commits to an action or deliverable',
      falseDescription: 'no commitment is made by the sender',
    ),
    'requests': AiDecisionQuestion.noul(
      instructions: 'Does the sender of `body` ask the recipient to do, send, '
          'decide, approve or answer something?',
      trueDescription: 'the sender is waiting on the recipient for something',
      falseDescription: 'nothing is asked of the recipient',
    ),
    'due': _dueQuestion,
    'urgency': _urgencyQuestion,
    'effort': effortQuestion,
  };

  /// Asked about a message the account holder received.
  static const Map<String, AiDecisionQuestion> inboxQuestions = {
    'needs_action': AiDecisionQuestion.noul(
      instructions: 'Does the email in `body` require the recipient to do '
          'something, make a decision, or reply?',
      trueDescription: 'the recipient is expected to act or answer',
      falseDescription: 'it is informational, or no response is expected',
    ),
    'commits': AiDecisionQuestion.noul(
      instructions: 'Does the sender of `body` promise to send, deliver or '
          'get back to the recipient about something?',
      trueDescription: 'the sender commits to deliver something to the '
          'recipient',
      falseDescription: 'the sender makes no such promise',
    ),
    'bulk': AiDecisionQuestion.noul(
      instructions: 'Is the email in `body` unsolicited bulk marketing, a '
          'newsletter, or an automated notification rather than a personal '
          'message?',
      trueDescription: 'marketing, newsletter, or automated notification',
      falseDescription: 'a message written to this recipient by a person',
    ),
    'due': _dueQuestion,
    'urgency': _urgencyQuestion,
    'effort': effortQuestion,
  };

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// The structured state shown to the model for [email].
  static Map<String, Object?> stateFor(Email email, {required bool outgoing}) {
    return {
      'direction': outgoing
          ? 'sent by the account holder'
          : 'received by the account holder',
      'subject': email.subject,
      'from': _label(email.from),
      'to': email.toRecipients.map(_label).join(', '),
      'date': _dateOf(email).toIso8601String(),
      'body': bodyExcerpt(email),
    };
  }

  /// What the estimate pass shows the model for a commitment without an
  /// estimate: the message itself when it is still in the recent mail, else
  /// the row's own reading of it.
  static Map<String, Object?> effortStateFor(
    Commitment commitment,
    Email? email,
    Set<String> selfAddresses,
  ) {
    if (email != null) {
      return stateFor(email, outgoing: _isFromSelf(email, selfAddresses));
    }
    return {
      'kind': switch (commitment.kind) {
        CommitmentKind.iOwe => 'a promise the account holder made',
        CommitmentKind.theyOweMe =>
          'something the account holder is waiting on',
        CommitmentKind.needsAction => 'a request the account holder received',
      },
      'subject': commitment.subject,
      'counterpart': _label(commitment.counterpart),
      'date': commitment.emailDate.toIso8601String(),
      'body': commitment.snippet,
    };
  }

  /// The raw answers as one log fragment: `needs_action=0.15 commits=0.25
  /// bulk=0.02 due=none urgency=1.24 effort=1.40` (sent mail lists
  /// `commits` and `requests` instead).
  static String describeAnswers(
    AiDecisionResponse response, {
    required bool outgoing,
  }) {
    final keys = outgoing
        ? const ['commits', 'requests']
        : const ['needs_action', 'commits', 'bulk'];
    return [
      for (final k in keys) '$k=${_num(response.answers[k])}',
      'due=${response.answers['due']?.choice ?? '-'}',
      'urgency=${_num(response.answers['urgency'])}',
      'effort=${_num(response.answers['effort'])}',
    ].join(' ');
  }

  static String _num(AiDecisionAnswer? answer) {
    final v = answer?.probability ?? answer?.score;
    return v == null ? '-' : v.toStringAsFixed(2);
  }

  /// Enough of a message id to find it in the cache; Graph ids run to 150
  /// characters.
  static String _shortId(String id) =>
      id.length <= 16 ? id : '${id.substring(0, 12)}…';

  /// The newest reply in the message, as plain text, capped at
  /// [maxBodyChars]; falls back to the provider's preview when no body has
  /// been cached (a folder listing carries previews only).
  static String bodyExcerpt(Email email) {
    final text = email.body.trim().isEmpty
        ? email.bodyPreview
        : latestReplyText(email.body, email.bodyType);
    final collapsed = text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    return collapsed.length <= maxBodyChars
        ? collapsed
        : collapsed.substring(0, maxBodyChars);
  }

  // ---------------------------------------------------------------------------
  // Answers → commitments
  // ---------------------------------------------------------------------------

  /// Turns the model's answers about [email] into zero, one or two
  /// commitments.
  static List<Commitment> commitmentsFrom(
    Email email,
    AiDecisionResponse response, {
    required bool outgoing,
    required String accountId,
    required Set<String> selfAddresses,
    required DateTime now,
  }) {
    double p(String key) => response.answers[key]?.probability ?? 0;
    if (!outgoing && p('bulk') >= threshold) return const [];

    final due = _dueFrom(response.answers['due']);
    final urgency = _urgencyFrom(response.answers['urgency']);
    final estimatedMinutes = minutesFrom(response.answers['effort']);
    final counterpart = outgoing
        ? _counterpartForSent(email, selfAddresses)
        : email.from;

    Commitment make(CommitmentKind kind, double confidence) => Commitment(
          id: Commitment.idFor(kind, email.id),
          accountId: accountId,
          emailId: email.id,
          conversationId: email.conversationId,
          kind: kind,
          status: CommitmentStatus.open,
          counterpart: counterpart,
          subject: email.subject,
          snippet: _snippet(email),
          due: due,
          urgency: urgency,
          confidence: confidence,
          emailDate: _dateOf(email),
          detectedAt: now,
          estimatedMinutes: estimatedMinutes,
        );

    final out = <Commitment>[];
    if (outgoing) {
      if (p('commits') >= threshold) {
        out.add(make(CommitmentKind.iOwe, p('commits')));
      }
      if (p('requests') >= threshold) {
        out.add(make(CommitmentKind.theyOweMe, p('requests')));
      }
    } else {
      if (p('needs_action') >= threshold) {
        out.add(make(CommitmentKind.needsAction, p('needs_action')));
      }
      if (p('commits') >= threshold) {
        out.add(make(CommitmentKind.theyOweMe, p('commits')));
      }
    }
    return out;
  }

  static CommitmentDue _dueFrom(AiDecisionAnswer? answer) {
    switch (answer?.choice) {
      case 'today':
        return CommitmentDue.today;
      case 'this_week':
        return CommitmentDue.thisWeek;
      case 'later':
        return CommitmentDue.later;
      default:
        return CommitmentDue.none;
    }
  }

  static int _urgencyFrom(AiDecisionAnswer? answer) {
    final score = answer?.score;
    if (score == null) return 0;
    return score.round().clamp(0, 2);
  }

  /// For a sent message: the first recipient who is not the account holder
  /// (To before Cc), falling back to the sender so the row still has a name.
  static EmailAddress _counterpartForSent(
    Email email,
    Set<String> selfAddresses,
  ) {
    for (final list in [email.toRecipients, email.ccRecipients]) {
      for (final a in list) {
        if (!selfAddresses.contains(a.address.toLowerCase())) return a;
      }
    }
    return email.from;
  }

  static String _snippet(Email email) {
    final text = bodyExcerpt(email).replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 160 ? text : '${text.substring(0, 157)}…';
  }

  // ---------------------------------------------------------------------------
  // Resolution
  // ---------------------------------------------------------------------------

  /// Whether the mail on hand has already settled [commitment]:
  ///
  /// * *they owe me* — the counterpart wrote back in the same thread after
  ///   the message that raised it;
  /// * *needs action* — the account holder replied in the same thread after
  ///   receiving it;
  /// * *I owe* — never; only the user can say a promise is kept.
  ///
  /// Without a thread id (IMAP) nothing can be matched, so nothing resolves.
  static bool isResolvedByMail(
    Commitment commitment, {
    required List<Email> sentEmails,
    required List<Email> inboxEmails,
    required Set<String> selfAddresses,
  }) {
    final thread = commitment.conversationId;
    if (thread == null || thread.isEmpty) return false;

    switch (commitment.kind) {
      case CommitmentKind.iOwe:
        return false;
      case CommitmentKind.theyOweMe:
        final who = commitment.counterpart.address.toLowerCase();
        return inboxEmails.any((e) =>
            e.conversationId == thread &&
            e.id != commitment.emailId &&
            e.from.address.toLowerCase() == who &&
            _dateOf(e).isAfter(commitment.emailDate));
      case CommitmentKind.needsAction:
        return sentEmails.any((e) =>
            e.conversationId == thread &&
            e.id != commitment.emailId &&
            _isFromSelf(e, selfAddresses) &&
            _dateOf(e).isAfter(commitment.emailDate));
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static bool _isFromSelf(Email email, Set<String> selfAddresses) =>
      selfAddresses.contains(email.from.address.toLowerCase());

  static DateTime _dateOf(Email email) =>
      email.sentDateTime ?? email.receivedDateTime;

  static String _label(EmailAddress a) {
    final name = a.name;
    return name == null || name.isEmpty ? a.address : '$name <${a.address}>';
  }
}

class _Candidate {
  const _Candidate(this.email, {required this.outgoing});
  final Email email;
  final bool outgoing;
}

class DetectCommitmentsParams extends Equatable {
  const DetectCommitmentsParams({
    required this.accountId,
    required this.selfAddresses,
    required this.sentEmails,
    required this.inboxEmails,
    required this.now,
    this.maxToClassify = 30,
  });

  final String accountId;

  /// The account holder's addresses, lower-cased: how "me" is told apart from
  /// everyone else on a message.
  final Set<String> selfAddresses;

  /// Recent mail from the Sent folder, any order.
  final List<Email> sentEmails;

  /// Recent mail from the Inbox, any order.
  final List<Email> inboxEmails;

  final DateTime now;

  /// Most messages shown to the model in one call. Each is one request, so
  /// this bounds both the time a refresh takes and what a metered API costs.
  final int maxToClassify;

  @override
  List<Object?> get props =>
      [accountId, selfAddresses, sentEmails, inboxEmails, now, maxToClassify];
}

class DetectCommitmentsResult extends Equatable {
  const DetectCommitmentsResult({
    required this.commitments,
    required this.classified,
    required this.remaining,
    required this.resolved,
    this.estimated = 0,
    this.model,
    this.warning,
  });

  /// The account's whole ledger after this run, all statuses.
  final List<Commitment> commitments;

  /// Messages shown to the model this run.
  final int classified;

  /// Unscanned messages left for a later run (over the cap, or after a
  /// mid-scan failure).
  final int remaining;

  /// Commitments the resolution pass closed this run.
  final int resolved;

  /// Older open commitments the estimate pass gave an effort estimate.
  final int estimated;

  /// The model that answered, as the provider named it (an alias such as
  /// `jev-latest` resolved to its version) — null when nothing was asked.
  final String? model;

  /// A provider failure that cut the scan short, when one did.
  final String? warning;

  @override
  List<Object?> get props =>
      [commitments, classified, remaining, resolved, estimated, model, warning];
}
