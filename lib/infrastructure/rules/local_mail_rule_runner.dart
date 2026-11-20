import 'package:flutter/foundation.dart';

import '../../core/error/exceptions.dart';
import '../../core/rules/mail_rule_matcher.dart';
import '../../data/datasources/local/mail_rule_store.dart';
import '../../data/datasources/remote/local_rule_mailbox.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_address.dart';
import '../../domain/entities/mail_rule.dart';
import '../accounts/account.dart';

/// What one run did, so the poller knows whether the Inbox has to be
/// re-listed even on a cycle whose counts it would otherwise trust.
class LocalRuleRunResult {
  const LocalRuleRunResult({this.processed = 0, this.changedInbox = false});

  static const none = LocalRuleRunResult();

  /// Messages the rules were offered.
  final int processed;

  /// A message in the Inbox was moved, deleted, marked read or flagged.
  final bool changedInbox;
}

/// Runs an IMAP account's rules — NightMail's own, since IMAP has no rules
/// API — on mail newly arrived in its Inbox.
///
/// Called by `MailPollerCubit` at the top of each IMAP account's cycle, in the
/// main window only and inside the account's connection gate, so the counts
/// and the Inbox page the poll then reads already reflect what the rules did.
/// Rules therefore act only while NightMail is running. See
/// `docs/claude/mail-rules.md` for the rules this follows; the two that keep
/// it safe are:
///
/// - **It never starts from 0.** No progress, unreadable progress, a rebuilt
///   Inbox (UIDVALIDITY changed) or rules switched on from none all start
///   from the Inbox's newest message and process nothing already there. A
///   start from 0 would move, delete or forward the whole Inbox history.
/// - **A message is claimed before it is acted on**, so it is acted on at
///   most once: a missed move leaves mail visibly in the Inbox, a repeated
///   forward goes out to other people. The claim is the saved progress and,
///   where the server keeps keywords, [claimKeyword] on the message itself,
///   which stops another device running the rules on it later. Only where
///   the server also has CONDSTORE is that claim a compare-and-set; without
///   it, two devices polling at the same moment can both act.
/// - **Nothing it does can feed itself.** No move or copy into the Inbox
///   (the copy would arrive as new mail and match again), and no forward of
///   a message that is itself automatic (`Auto-Submitted`), while every
///   forward it sends is marked so.
class LocalMailRuleRunner {
  LocalMailRuleRunner({required this._store, this._isMigrationTarget});

  final MailRuleStore _store;

  /// Whether a migration job is copying mail into the account. Those copies
  /// arrive as new Inbox UIDs, and the rules — maybe the ones the migration
  /// itself just copied over — would forward, file or delete mail the old
  /// server's rules already handled.
  final Future<bool> Function(String accountId)? _isMigrationTarget;

  /// Stored on a message once a device has offered it to the rules.
  static const claimKeyword = r'$NightMailRules';

  /// Messages per cycle. A week's backlog after a long sleep is worked
  /// through over several polls rather than holding the account's connection
  /// gate through one.
  static const batchLimit = 50;

  static const _flagged = r'\Flagged';

  Future<LocalRuleRunResult> run(
    ImapAccount account,
    LocalRuleMailbox mailbox,
  ) async {
    final rules = [
      for (final r in await _store.loadRules(account.id))
        if (r.enabled &&
            !r.hasUnsupportedParts &&
            r.conditions.isNotEmpty &&
            r.actions.isNotEmpty)
          r,
    ];
    if (rules.isEmpty ||
        (await _isMigrationTarget?.call(account.id) ?? false)) {
      // Also while a migration is filling the Inbox: forgetting progress
      // means the rules restart from "now" once it is done, past every
      // copied message.
      // Forgotten, so switching a rule on later starts from that moment
      // rather than working through everything that arrived meanwhile.
      await _store.clearProgress(account.id);
      return LocalRuleRunResult.none;
    }

    final progress = await _store.loadProgress(account.id);
    if (progress == null) {
      await _startFromNow(
        account,
        await mailbox.fetchInboxArrivals(afterUid: null, limit: 0),
        'rules switched on',
      );
      return LocalRuleRunResult.none;
    }

    final arrivals = await mailbox.fetchInboxArrivals(
      afterUid: progress.lastUid,
      limit: batchLimit,
      excludeKeyword: claimKeyword,
    );
    if (arrivals.uidValidity != progress.uidValidity) {
      await _startFromNow(account, arrivals, 'Inbox UIDVALIDITY changed');
      return LocalRuleRunResult.none;
    }

    final matcher = MailRuleMatcher(
      myAddresses: [account.emailAddress, ...?account.aliases],
    );
    final needsBody = MailRuleMatcher.needsBody(rules);
    var lastUid = progress.lastUid;
    var processed = 0;
    var changed = false;
    final failures = _FailureStreak();

    for (final message in arrivals.messages) {
      final uid = _uidOf(message.id);
      lastUid = uid;
      // Claimed before anything is done to it — see the class doc.
      await _store.saveProgress(
        account.id,
        MailRuleProgress(uidValidity: arrivals.uidValidity, lastUid: uid),
      );
      if (arrivals.keywordsAllowed) {
        // A failure here propagates and ends the run: a plain flag write
        // almost only fails when the connection has gone, and carrying on
        // would claim every remaining message and act on none of them.
        final won = await mailbox.claim(
          message.id,
          claimKeyword,
          unchangedSince: arrivals.modSequences[message.id],
        );
        if (!won) {
          debugPrint('[MailRules] ${account.id}: ${message.id} was claimed '
              'by another device');
          continue;
        }
      }
      processed++;

      Email email = message;
      if (needsBody) email = await _peek(account, mailbox, message);
      final actions = actionsFor(rules, email, matcher);
      if (actions.isEmpty) continue;
      final autoSubmitted = arrivals.autoSubmitted.contains(message.id);
      if (await _apply(
        account,
        mailbox,
        email,
        actions,
        autoSubmitted: autoSubmitted,
        failures: failures,
      )) {
        changed = true;
      }
    }

    // Everything below UIDNEXT-as-selected that was not offered was already
    // claimed by another device or deleted, so progress can skip it — unless
    // this batch hit the cap and more are still waiting.
    final lastExisting = arrivals.lastExistingUid;
    if (arrivals.messages.length < batchLimit &&
        lastExisting != null &&
        lastExisting > lastUid) {
      await _store.saveProgress(
        account.id,
        MailRuleProgress(uidValidity: arrivals.uidValidity, lastUid: lastExisting),
      );
    }

    if (processed > 0) {
      debugPrint('[MailRules] ${account.id}: offered $processed new '
          'message(s) to ${rules.length} rule(s)');
    }
    return LocalRuleRunResult(processed: processed, changedInbox: changed);
  }

  /// The actions [email] triggers, in rule order. A rule that stops
  /// processing, or that moves or deletes the message, ends the list: later
  /// rules would be acting on a message that is no longer in the Inbox. The
  /// first rule to name an action decides its value.
  @visibleForTesting
  static List<MailRuleAction> actionsFor(
    List<MailRule> rules,
    Email email,
    MailRuleMatcher matcher,
  ) {
    final actions = <MailRuleAction>[];
    for (final rule in [...rules]..sort((a, b) => a.sequence.compareTo(b.sequence))) {
      if (!matcher.matches(rule, email)) continue;
      for (final a in rule.actions) {
        if (!actions.any((x) => x.kind == a.kind)) actions.add(a);
      }
      if (rule.actions.any(
        (a) =>
            a.kind == MailRuleActionKind.stopProcessingRules ||
            _removesFromInbox(a.kind),
      )) {
        break;
      }
    }
    return actions;
  }

  static bool _removesFromInbox(MailRuleActionKind kind) =>
      kind == MailRuleActionKind.moveToFolder ||
      kind == MailRuleActionKind.delete;

  /// Applies [actions], those that leave the message where it is first and
  /// the one move or delete last — it changes the message's id, and the
  /// first of the two wins. A refusal from the server is logged and the next
  /// action tried; losing the network, or a second failure in a row (the
  /// datasource reports most dropped connections as a plain IMAP error),
  /// stops the run.
  Future<bool> _apply(
    ImapAccount account,
    LocalRuleMailbox mailbox,
    Email email,
    List<MailRuleAction> actions, {
    required bool autoSubmitted,
    required _FailureStreak failures,
  }) async {
    var changed = false;
    final ordered = [
      ...actions.where((a) => !_removesFromInbox(a.kind)),
      ...actions.where((a) => _removesFromInbox(a.kind)).take(1),
    ];
    for (final action in ordered) {
      try {
        switch (action.kind) {
          case MailRuleActionKind.markAsRead:
            await mailbox.updateEmailReadStatus(id: email.id, isRead: true);
            changed = true;
          case MailRuleActionKind.star:
            await mailbox.addFlags(email.id, [_flagged]);
            changed = true;
          case MailRuleActionKind.forwardTo:
            if (autoSubmitted) {
              debugPrint('[MailRules] ${account.id}: ${email.id} is an '
                  'automatic message — not forwarded');
              continue;
            }
            await _forward(account, mailbox, email, action.addresses);
          case MailRuleActionKind.copyToFolder ||
              MailRuleActionKind.moveToFolder
              when isInbox(action.folderId):
            debugPrint('[MailRules] ${account.id}: ${action.kind.name} into '
                'the Inbox refused — it would arrive as new mail again');
            continue;
          case MailRuleActionKind.copyToFolder:
            await mailbox.copyEmail(email.id, action.folderId!);
          case MailRuleActionKind.moveToFolder:
            await mailbox.moveEmail(email.id, action.folderId!);
            changed = true;
          case MailRuleActionKind.delete:
            await mailbox.trashEmail(email.id);
            changed = true;
          case MailRuleActionKind.stopProcessingRules:
            break;
          default:
            debugPrint('[MailRules] ${account.id}: ${action.kind.name} is not '
                'available on IMAP, skipped');
            continue;
        }
        failures.reset();
        debugPrint('[MailRules] ${account.id}: ${action.kind.name} '
            '${email.id}');
      } on NetworkException {
        rethrow;
      } catch (e) {
        debugPrint('[MailRules] ${account.id}: ${action.kind.name} on '
            '${email.id} failed: $e');
        if (failures.fail()) rethrow;
      }
    }
    return changed;
  }

  /// IMAP's Inbox is `INBOX` in any case (RFC 3501).
  @visibleForTesting
  static bool isInbox(String? folderId) => folderId?.toUpperCase() == 'INBOX';

  /// Forwards [email], never to the account itself: two accounts forwarding
  /// to each other, or one to itself, would loop with nothing to stop it.
  Future<void> _forward(
    ImapAccount account,
    LocalRuleMailbox mailbox,
    Email email,
    List<String> addresses,
  ) async {
    final own = {
      account.emailAddress.toLowerCase(),
      ...?account.aliases?.map((a) => a.toLowerCase()),
    };
    final to = [
      for (final a in addresses)
        if (a.trim().isNotEmpty && !own.contains(a.trim().toLowerCase()))
          a.trim(),
    ];
    if (to.isEmpty) {
      debugPrint('[MailRules] ${account.id}: forward to the account itself '
          'refused');
      return;
    }
    final full = email.body.isEmpty ? await mailbox.peekEmail(email.id) : email;
    final html = full.bodyType == EmailBodyType.html;
    await mailbox.forwardForRule(
      messageId: full.id,
      toAddresses: to,
      comment: forwardBody(full),
      bodyType: html ? EmailBodyType.html : EmailBodyType.text,
    );
  }

  /// The forward's body: the usual header block, then the original.
  @visibleForTesting
  static String forwardBody(Email email) {
    String who(EmailAddress a) =>
        (a.name?.isNotEmpty ?? false) ? '${a.name} <${a.address}>' : a.address;
    final lines = [
      '---------- Forwarded message ---------',
      'From: ${who(email.from)}',
      'Date: ${email.receivedDateTime.toLocal()}',
      'Subject: ${email.subject}',
      if (email.toRecipients.isNotEmpty)
        'To: ${email.toRecipients.map(who).join(', ')}',
    ];
    if (email.bodyType != EmailBodyType.html) {
      return '${lines.join('\n')}\n\n${email.body}';
    }
    final header = lines.map(_escapeHtml).join('<br>');
    return '<div>$header</div><br>${email.body}';
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  Future<Email> _peek(
    ImapAccount account,
    LocalRuleMailbox mailbox,
    Email message,
  ) async {
    try {
      return await mailbox.peekEmail(message.id);
    } on NetworkException {
      rethrow;
    } catch (e) {
      // Tested on the envelope alone: a body condition then cannot match,
      // which errs towards doing nothing.
      debugPrint('[MailRules] ${account.id}: could not read ${message.id}: $e');
      return message;
    }
  }

  Future<void> _startFromNow(
    ImapAccount account,
    InboxArrivals arrivals,
    String why,
  ) async {
    final last = arrivals.lastExistingUid;
    if (last == null) {
      // A server that names no UIDNEXT gives no safe place to start; try
      // again next cycle rather than guess.
      debugPrint('[MailRules] ${account.id}: Inbox reported no UIDNEXT — '
          'rules not started');
      return;
    }
    debugPrint('[MailRules] ${account.id}: starting after UID $last ($why)');
    await _store.saveProgress(
      account.id,
      MailRuleProgress(uidValidity: arrivals.uidValidity, lastUid: last),
    );
  }

  static int _uidOf(String id) =>
      int.tryParse(id.substring(id.lastIndexOf(':') + 1)) ?? 0;
}

/// Consecutive action failures across one run.
class _FailureStreak {
  int _count = 0;

  void reset() => _count = 0;

  /// Records a failure; true once two have happened in a row.
  bool fail() => ++_count >= 2;
}
