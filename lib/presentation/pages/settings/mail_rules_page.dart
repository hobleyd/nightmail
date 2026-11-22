import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/email_folder.dart';
import '../../../domain/entities/mail_rule.dart';
import '../../../injection_container.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../blocs/account/account_cubit.dart';
import '../../blocs/mail_rules/mail_rules_cubit.dart';
import '../../blocs/mail_rules/mail_rules_state.dart';
import '../../widgets/adaptive_alert_dialog.dart';
import '../../widgets/adaptive_switch.dart';

/// The Rules settings section.
///
/// Edits the mailbox's *server-side* rules — Graph's inbox `messageRules`
/// (Nightware implements the same resource), Gmail's filters — so they run
/// however the user reads their mail and nothing here is stored by the app.
/// Graph is the standard: the editor offers whatever the account's
/// [MailRuleCapabilities] say, so a Gmail account simply sees fewer kinds of
/// condition and action. Self-contained the way `OutOfOfficePage` is, for the
/// same reason: the mobile section route builds its own, narrower providers.
class MailRulesPage extends StatelessWidget {
  const MailRulesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<MailRulesCubit>(
      create: (_) => sl<MailRulesCubit>()..load(),
      child: const _MailRulesView(),
    );
  }
}

class _MailRulesView extends StatelessWidget {
  const _MailRulesView();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MailRulesCubit, MailRulesState>(
      listenWhen: (a, b) => a.savedAt != b.savedAt && b.savedAt != null,
      listener: (context, state) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Rules updated')),
        );
      },
      builder: (context, state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AccountPicker(),
            const SizedBox(height: 16),
            Expanded(child: _body(context, state)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, MailRulesState state) {
    switch (state.status) {
      case MailRulesStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case MailRulesStatus.unsupported:
        return _Notice(
          icon: Icons.info_outline_rounded,
          text:
              state.errorMessage ?? 'Rules are not available for this account.',
        );
      case MailRulesStatus.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Notice(
              icon: Icons.error_outline_rounded,
              text: state.errorMessage ?? 'Could not load rules.',
              isError: true,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.read<MailRulesCubit>().load(),
              style: TextButton.styleFrom(foregroundColor: AppColors.accent),
              child: const Text('Try again'),
            ),
          ],
        );
      case MailRulesStatus.ready:
        return _RuleList(state: state);
    }
  }
}

/// The account being edited, which decides the provider's wording (Gmail
/// files with labels, not folders).
Account? _accountFor(BuildContext context, String? id) {
  final state = context.read<AccountCubit>().state;
  if (id == null || state is! AccountsLoaded) return null;
  for (final a in state.accounts) {
    if (a.id == id) return a;
  }
  return null;
}

class _RuleList extends StatelessWidget {
  const _RuleList({required this.state});

  final MailRulesState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final caps = state.capabilities!;
    final google = _accountFor(context, state.accountId) is GmailAccount;
    final rules = state.rules;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                // Local rules have to say so plainly: they are the one kind
                // that stops when the app does.
                !caps.runsOnServer
                    ? 'This server keeps no rules of its own, so these run in '
                          'NightMail, on this device, while it is open — on '
                          'new mail as it reaches the Inbox, top to bottom. '
                          'Mail that arrives while NightMail is closed is '
                          'handled when it next opens.'
                    : caps.ordered
                    ? 'Rules run on the server as mail arrives in the Inbox, '
                          'top to bottom, so they apply however you read your '
                          'mail.'
                    : 'Filters run on the server as mail arrives, so they '
                          'apply however you read your mail. Gmail runs every '
                          'matching filter; they have no order.',
                style: TextStyle(color: c.textMuted, fontSize: 12, height: 1.4),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: state.busy ? null : () => _openEditor(context, null),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: Text(google ? 'New filter' : 'New rule'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: rules.isEmpty
              ? Center(
                  child: Text(
                    google
                        ? 'This mailbox has no filters.'
                        : 'This mailbox has no rules.',
                    style: TextStyle(color: c.textMuted, fontSize: 13),
                  ),
                )
              : ListView.separated(
                  itemCount: rules.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _RuleTile(
                    rule: rules[i],
                    state: state,
                    google: google,
                    onEdit: () => _openEditor(context, rules[i]),
                  ),
                ),
        ),
        if (state.errorMessage != null) ...[
          const SizedBox(height: 8),
          _Notice(
            icon: Icons.error_outline_rounded,
            text: state.errorMessage!,
            isError: true,
          ),
        ],
        if (state.needsPermission) ...[
          const SizedBox(height: 8),
          Text(
            'Changing rules needs one extra permission — you will be asked '
            'for it the first time.',
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
        ],
      ],
    );
  }

  Future<void> _openEditor(BuildContext context, MailRule? rule) async {
    final cubit = context.read<MailRulesCubit>();
    final google = _accountFor(context, state.accountId) is GmailAccount;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RuleEditorDialog(
        initial: rule ?? const MailRule(),
        capabilities: state.capabilities!,
        folders: state.folders,
        google: google,
        onSave: (draft) async {
          if (!await _ensurePermission(context, cubit, google)) return null;
          final ok = await cubit.saveRule(draft);
          return ok ? null : (cubit.state.errorMessage ?? 'Could not save.');
        },
      ),
    );
  }
}

/// Says that the provider is about to ask *before* running the consent flow,
/// then runs it — the Out of Office screen's shape. False means stop: either
/// the user cancelled or the provider declined, and neither is an error.
Future<bool> _ensurePermission(
  BuildContext context,
  MailRulesCubit cubit,
  bool google,
) async {
  if (!cubit.state.needsPermission) return true;
  final provider = google ? 'Google' : 'Microsoft';
  final proceed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AdaptiveAlertDialog(
      title: const Text('Permission needed'),
      content: Text(
        'Changing ${google ? 'filters' : 'rules'} needs one extra permission '
        'on this account. $provider will ask you to sign in and approve it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  if (proceed != true) return false;
  return cubit.requestPermission();
}

// ─── New rule from a message ──────────────────────────────────────────────

/// Opens the rule editor on the active account — the one the mail list is
/// showing — already holding a "from" condition for [email]'s sender: the
/// mail list's rule button. The actions are left to the user; guessing one
/// (move it? delete it?) would put a destructive default one click from Save.
Future<void> showNewRuleForEmail(BuildContext context, Email email) {
  // Handed in rather than looked up from the dialog: the cubit the mail list
  // sees may be provided below the MaterialApp, out of a dialog route's reach.
  final accountCubit = context.read<AccountCubit>();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => MultiBlocProvider(
      providers: [
        BlocProvider.value(value: accountCubit),
        BlocProvider<MailRulesCubit>(
          create: (_) => sl<MailRulesCubit>()..load(),
        ),
      ],
      child: _NewRuleForEmailDialog(email: email),
    ),
  );
}

/// The rule editor once the account's rules (and so its capabilities and
/// folders) have loaded; a spinner, or why not, until then.
class _NewRuleForEmailDialog extends StatelessWidget {
  const _NewRuleForEmailDialog({required this.email});

  final Email email;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MailRulesCubit, MailRulesState>(
      // Only the status: the editor holds its own draft, and a save's busy
      // and re-read states are none of this dialog's business.
      buildWhen: (a, b) => a.status != b.status,
      builder: (context, state) {
        final c = context.colors;
        switch (state.status) {
          case MailRulesStatus.loading:
            return Dialog(
              backgroundColor: c.surfacePanel,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            );
          case MailRulesStatus.unsupported:
          case MailRulesStatus.error:
            return AdaptiveAlertDialog(
              title: const Text('Rules unavailable'),
              content: Text(
                state.errorMessage ??
                    'Rules are not available for this account.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          case MailRulesStatus.ready:
            final cubit = context.read<MailRulesCubit>();
            final caps = state.capabilities!;
            final account = _accountFor(context, state.accountId);
            final google = account is GmailAccount;
            final sender = _senderCondition(email, caps, account);
            return _RuleEditorDialog(
              initial: MailRule(conditions: [?sender]),
              capabilities: caps,
              folders: state.folders,
              google: google,
              onSave: (draft) async {
                if (!await _ensurePermission(context, cubit, google)) {
                  return null;
                }
                final ok = await cubit.saveRule(draft);
                return ok
                    ? null
                    : (cubit.state.errorMessage ?? 'Could not save.');
              },
            );
        }
      },
    );
  }
}

/// "From [email]'s sender", in the strongest form the provider has: Graph's
/// and IMAP's exact address match, or Gmail's "from contains". None for the
/// account's own message (Sent): rules run on arriving mail, and "from me"
/// would never match it.
MailRuleCondition? _senderCondition(
  Email email,
  MailRuleCapabilities caps,
  Account? account,
) {
  final address = email.from.address.trim();
  if (address.isEmpty ||
      address.toLowerCase() == account?.emailAddress.toLowerCase()) {
    return null;
  }
  for (final kind in const [
    MailRuleConditionKind.fromAddresses,
    MailRuleConditionKind.senderContains,
  ]) {
    if (caps.conditions.contains(kind)) {
      return MailRuleCondition(kind, values: [address]);
    }
  }
  return null;
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.state,
    required this.google,
    required this.onEdit,
  });

  final MailRule rule;
  final MailRulesState state;
  final bool google;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final caps = state.capabilities!;
    final cubit = context.read<MailRulesCubit>();
    final busy = state.busy;
    final summary = describeMailRule(
      rule,
      state.folderById,
      google: google,
      local: !caps.runsOnServer,
    );
    final title = rule.name.isNotEmpty ? rule.name : summary;

    Future<void> guarded(Future<void> Function() change) async {
      if (!await _ensurePermission(context, cubit, google)) return;
      await change();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: rule.enabled ? c.textPrimary : c.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (rule.name.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    summary,
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                ],
                if (rule.hasError) ...[
                  const SizedBox(height: 4),
                  const _Notice(
                    icon: Icons.error_outline_rounded,
                    text:
                        'The server reports a problem with this rule — '
                        'usually a folder it uses has been deleted.',
                    isError: true,
                  ),
                ],
                if (!rule.isEditable) ...[
                  const SizedBox(height: 4),
                  _Notice(
                    icon: Icons.lock_outline_rounded,
                    text: rule.isReadOnly
                        ? 'This rule can only be changed in Outlook.'
                        : 'Uses settings NightMail cannot show, so it can be '
                              'turned on or off, moved or deleted here but '
                              'only edited in ${google ? 'Gmail' : 'Outlook'}.',
                  ),
                ],
              ],
            ),
          ),
          if (caps.ordered) ...[
            IconButton(
              tooltip: 'Run earlier',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: busy || !cubit.canMove(rule, -1)
                  ? null
                  : () => guarded(() => cubit.move(rule, -1)),
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
            IconButton(
              tooltip: 'Run later',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: busy || !cubit.canMove(rule, 1)
                  ? null
                  : () => guarded(() => cubit.move(rule, 1)),
              icon: const Icon(Icons.arrow_downward_rounded),
            ),
          ],
          IconButton(
            tooltip: 'Edit',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: busy || !rule.isEditable ? null : onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Delete',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: busy || rule.isReadOnly
                ? null
                : () => guarded(() => _confirmDelete(context, cubit, title)),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          if (caps.canDisable)
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 6),
              child: AdaptiveSwitch(
                value: rule.enabled,
                onChanged: busy || rule.isReadOnly
                    ? null
                    : (v) => guarded(() => cubit.setEnabled(rule, v)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    MailRulesCubit cubit,
    String title,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AdaptiveAlertDialog(
        title: Text(google ? 'Delete Filter' : 'Delete Rule'),
        content: Text('Delete "$title"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await cubit.deleteRule(rule);
  }
}

// ─── Wording ──────────────────────────────────────────────────────────────

/// What a condition is called. Gmail's wording follows its own filter form
/// ("Has the words"), because what Gmail matches is search text rather than
/// Graph's literal substrings.
String mailRuleConditionLabel(MailRuleConditionKind kind, {bool google = false}) =>
    switch (kind) {
      MailRuleConditionKind.fromAddresses => 'From',
      MailRuleConditionKind.senderContains =>
        google ? 'From' : 'Sender address contains',
      MailRuleConditionKind.sentToAddresses => 'Sent to',
      MailRuleConditionKind.recipientContains =>
        google ? 'To' : 'Recipient address contains',
      MailRuleConditionKind.subjectContains =>
        google ? 'Subject' : 'Subject contains',
      MailRuleConditionKind.bodyContains => 'Body contains',
      MailRuleConditionKind.bodyOrSubjectContains =>
        google ? 'Has the words' : 'Subject or body contains',
      MailRuleConditionKind.headerContains => 'Message header contains',
      MailRuleConditionKind.hasAttachments => 'Has an attachment',
      MailRuleConditionKind.importance => 'Importance is',
      MailRuleConditionKind.sentToMe => "I'm on the To line",
      MailRuleConditionKind.sentOnlyToMe => 'Sent only to me',
      MailRuleConditionKind.sentCcMe => "I'm on the Cc line",
      MailRuleConditionKind.sentToOrCcMe => "I'm on the To or Cc line",
      MailRuleConditionKind.notSentToMe => "I'm not on the To line",
      MailRuleConditionKind.isAutomaticReply => 'Is an automatic reply',
      MailRuleConditionKind.isMeetingRequest => 'Is a meeting invitation',
      MailRuleConditionKind.isMeetingResponse => 'Is a meeting response',
      MailRuleConditionKind.isNonDeliveryReport => 'Is a non-delivery report',
      MailRuleConditionKind.isReadReceipt => 'Is a read receipt',
      MailRuleConditionKind.isEncrypted => 'Is encrypted',
      MailRuleConditionKind.isSigned => 'Is digitally signed',
      MailRuleConditionKind.minimumSize => 'Size is at least (KB)',
      MailRuleConditionKind.maximumSize => 'Size is at most (KB)',
    };

/// What an action is called. Gmail files with labels, and a "move" there is
/// a label plus skipping the inbox, so it is named that way.
String mailRuleActionLabel(
  MailRuleActionKind kind, {
  bool google = false,
  bool local = false,
}) =>
    switch (kind) {
      MailRuleActionKind.moveToFolder =>
        google ? 'Apply label and skip the Inbox' : 'Move to folder',
      MailRuleActionKind.copyToFolder =>
        google ? 'Apply label' : 'Copy to folder',
      MailRuleActionKind.delete => google
          ? 'Delete'
          : local
          ? 'Delete (to Trash)'
          : 'Delete (to Deleted Items)',
      MailRuleActionKind.permanentDelete => 'Delete permanently',
      MailRuleActionKind.markAsRead => 'Mark as read',
      MailRuleActionKind.markImportance =>
        google ? 'Importance' : 'Mark importance as',
      MailRuleActionKind.forwardTo => 'Forward to',
      MailRuleActionKind.forwardAsAttachmentTo => 'Forward as attachment to',
      MailRuleActionKind.redirectTo => 'Redirect to',
      MailRuleActionKind.stopProcessingRules => 'Stop processing more rules',
      MailRuleActionKind.archive => 'Skip the Inbox (archive)',
      // IMAP's \Flagged, which is what this action sets on a local rule.
      MailRuleActionKind.star => local ? 'Flag it' : 'Star it',
      MailRuleActionKind.neverSpam => 'Never send to Spam',
    };

String _importanceLabel(
  MailRuleImportance importance, {
  bool google = false,
  bool asAction = false,
}) {
  if (google && asAction) {
    return importance == MailRuleImportance.high
        ? 'Always mark as important'
        : 'Never mark as important';
  }
  return switch (importance) {
    MailRuleImportance.low => 'Low',
    MailRuleImportance.normal => 'Normal',
    MailRuleImportance.high => 'High',
  };
}

/// One line describing a rule, for the list and for Gmail filters, which
/// have no name of their own.
String describeMailRule(
  MailRule rule,
  EmailFolder? Function(String? id) folderById, {
  bool google = false,
  bool local = false,
}) {
  String condition(MailRuleCondition c) {
    final label = mailRuleConditionLabel(c.kind, google: google);
    return switch (c.kind.valueType) {
      MailRuleValueType.text || MailRuleValueType.addresses =>
        '$label "${c.values.where((v) => v.trim().isNotEmpty).join('" or "')}"',
      MailRuleValueType.flag => label,
      MailRuleValueType.importance =>
        '$label ${_importanceLabel(c.importance ?? MailRuleImportance.normal).toLowerCase()}',
      MailRuleValueType.size => '$label ${c.sizeKb ?? 0}',
    };
  }

  String action(MailRuleAction a) {
    final label = mailRuleActionLabel(a.kind, google: google, local: local);
    return switch (a.kind.valueType) {
      MailRuleActionValueType.none => label,
      MailRuleActionValueType.folder =>
        '$label "${folderById(a.folderId)?.displayName ?? 'an unknown ${google ? 'label' : 'folder'}'}"',
      MailRuleActionValueType.importance => google
          ? _importanceLabel(a.importance!, google: true, asAction: true)
          : '$label ${_importanceLabel(a.importance!).toLowerCase()}',
      MailRuleActionValueType.addresses => '$label ${a.addresses.join(', ')}',
    };
  }

  final when = rule.conditions.isEmpty
      ? 'Every message'
      : rule.conditions.map(condition).join(', ');
  final except = rule.exceptions.isEmpty
      ? ''
      : ' (except: ${rule.exceptions.map(condition).join(', ')})';
  final then = rule.actions.isEmpty
      ? 'nothing'
      : rule.actions.map(action).join(', ');
  return '$when$except → $then';
}

// ─── Editor ───────────────────────────────────────────────────────────────

/// Creates or edits one rule. Holds its own draft: nothing reaches the cubit
/// until Save, and a failed save keeps the dialog open with the reason.
class _RuleEditorDialog extends StatefulWidget {
  const _RuleEditorDialog({
    required this.initial,
    required this.capabilities,
    required this.folders,
    required this.google,
    required this.onSave,
  });

  final MailRule initial;
  final MailRuleCapabilities capabilities;
  final List<EmailFolder> folders;
  final bool google;

  /// Null when the rule landed, otherwise why it did not.
  final Future<String?> Function(MailRule draft) onSave;

  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  late final TextEditingController _name;
  late List<MailRuleCondition> _conditions;
  late List<MailRuleCondition> _exceptions;
  late List<MailRuleAction> _actions;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial.name);
    _conditions = [...widget.initial.conditions];
    _exceptions = [...widget.initial.exceptions];
    _actions = [...widget.initial.actions];
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _isNew => widget.initial.id == null;

  MailRule get _draft => widget.initial.copyWith(
    name: _name.text.trim(),
    conditions: _conditions,
    exceptions: _exceptions,
    actions: _actions,
  );

  /// Why Save is refused, or null. Checked here rather than left to the
  /// provider, which answers a bare 400 for every one of these.
  String? get _problem {
    if (_conditions.isEmpty) {
      return 'Add at least one condition — a rule with none would act on '
          'every message.';
    }
    if (_actions.isEmpty) return 'Add at least one action.';
    if (_conditions.any((c) => !c.isComplete) ||
        _exceptions.any((c) => !c.isComplete)) {
      return 'Fill in every condition, or remove the empty ones.';
    }
    if (_actions.any((a) => !a.isComplete)) {
      return 'Fill in every action, or remove the empty ones.';
    }
    return null;
  }

  Future<void> _save() async {
    var draft = _draft;
    // Graph needs a name; a blank one is given the rule's own description,
    // which is what the list would show anyway.
    if (widget.capabilities.namedRules && draft.name.isEmpty) {
      final summary = describeMailRule(
        draft,
        _folderById,
        google: widget.google,
        local: !widget.capabilities.runsOnServer,
      );
      draft = draft.copyWith(
        name: summary.length > 80 ? '${summary.substring(0, 79)}…' : summary,
      );
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSave(draft);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  EmailFolder? _folderById(String? id) {
    for (final f in widget.folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final caps = widget.capabilities;
    final noun = widget.google ? 'Filter' : 'Rule';
    final problem = _problem;
    final size = MediaQuery.sizeOf(context);

    return Dialog(
      backgroundColor: c.surfacePanel,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: size.height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isNew ? 'New $noun' : 'Edit $noun',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (caps.namedRules) ...[
                        _sectionLabel(c, 'Name'),
                        _textField(
                          c,
                          controller: _name,
                          hint: 'Left blank, the rule is named after what it does',
                        ),
                        const SizedBox(height: 16),
                      ],
                      _sectionLabel(c, 'When a message arrives that matches all of'),
                      ..._conditionRows(c, 'if', _conditions, (l) => _conditions = l),
                      _addMenu<MailRuleConditionKind>(
                        label: 'Add condition',
                        options: _remaining(caps.conditions, _conditions),
                        labelOf: (k) =>
                            mailRuleConditionLabel(k, google: widget.google),
                        onSelected: (k) => setState(
                          () => _conditions = [..._conditions, _newCondition(k)],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _sectionLabel(c, 'Do the following'),
                      ..._actionRows(c),
                      _addMenu<MailRuleActionKind>(
                        label: 'Add action',
                        options: [
                          for (final k in MailRuleActionKind.values)
                            if (caps.actions.contains(k) &&
                                !_actions.any((a) => a.kind == k))
                              k,
                        ],
                        labelOf: (k) =>
                            mailRuleActionLabel(
                              k,
                              google: widget.google,
                              local: !widget.capabilities.runsOnServer,
                            ),
                        onSelected: (k) => setState(
                          () => _actions = [..._actions, _newAction(k)],
                        ),
                      ),
                      if (caps.exceptions.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _sectionLabel(c, 'Except if any of'),
                        ..._conditionRows(c, 'except', _exceptions, (l) => _exceptions = l),
                        _addMenu<MailRuleConditionKind>(
                          label: 'Add exception',
                          options: _remaining(caps.exceptions, _exceptions),
                          labelOf: (k) =>
                              mailRuleConditionLabel(k, google: widget.google),
                          onSelected: (k) => setState(
                            () => _exceptions = [..._exceptions, _newCondition(k)],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_error != null) ...[
                _Notice(
                  icon: Icons.error_outline_rounded,
                  text: _error!,
                  isError: true,
                ),
                const SizedBox(height: 8),
              ] else if (problem != null &&
                  (_conditions.isNotEmpty || _actions.isNotEmpty)) ...[
                // Not shown on a blank new rule: telling somebody what is
                // missing before they have started reads as a scolding.
                _Notice(icon: Icons.info_outline_rounded, text: problem),
                const SizedBox(height: 8),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  if (_saving)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    FilledButton(
                      onPressed: problem == null ? _save : null,
                      child: const Text('Save'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<MailRuleConditionKind> _remaining(
    Set<MailRuleConditionKind> allowed,
    List<MailRuleCondition> present,
  ) => [
    for (final k in MailRuleConditionKind.values)
      if (allowed.contains(k) && !present.any((c) => c.kind == k)) k,
  ];

  MailRuleCondition _newCondition(MailRuleConditionKind kind) =>
      switch (kind.valueType) {
        MailRuleValueType.importance => MailRuleCondition(
          kind,
          importance: MailRuleImportance.high,
        ),
        _ => MailRuleCondition(kind),
      };

  MailRuleAction _newAction(MailRuleActionKind kind) =>
      switch (kind.valueType) {
        MailRuleActionValueType.importance => MailRuleAction(
          kind,
          importance: widget.capabilities.markImportanceValues.contains(
                MailRuleImportance.high,
              )
              ? MailRuleImportance.high
              : widget.capabilities.markImportanceValues.first,
        ),
        _ => MailRuleAction(kind),
      };

  List<Widget> _conditionRows(
    AppColors c,
    String keyPrefix,
    List<MailRuleCondition> list,
    void Function(List<MailRuleCondition>) assign,
  ) {
    void replace(int i, MailRuleCondition next) =>
        setState(() => assign([...list]..[i] = next));

    return [
      for (var i = 0; i < list.length; i++)
        _Row(
          // One row per kind, so the kind is a stable key across removals
          // and keystrokes — a key that changed with the list would rebuild
          // the text field under the caret on every character.
          key: ValueKey('$keyPrefix-${list[i].kind}'),
          label: mailRuleConditionLabel(list[i].kind, google: widget.google),
          onRemove: () => setState(() => assign([...list]..removeAt(i))),
          child: switch (list[i].kind.valueType) {
            MailRuleValueType.text || MailRuleValueType.addresses => _textField(
              c,
              initial: list[i].values.join('; '),
              hint: list[i].kind.valueType == MailRuleValueType.addresses
                  ? 'name@example.com; another@example.com'
                  : 'Separate alternatives with ;',
              onChanged: (t) => replace(
                i,
                MailRuleCondition(list[i].kind, values: _split(t)),
              ),
            ),
            MailRuleValueType.flag => null,
            MailRuleValueType.importance => _Dropdown<MailRuleImportance>(
              value: list[i].importance,
              items: [
                for (final v in MailRuleImportance.values)
                  DropdownMenuItem(value: v, child: Text(_importanceLabel(v))),
              ],
              onChanged: (v) => replace(
                i,
                MailRuleCondition(list[i].kind, importance: v),
              ),
            ),
            MailRuleValueType.size => _textField(
              c,
              initial: list[i].sizeKb?.toString() ?? '',
              hint: 'KB',
              number: true,
              onChanged: (t) => replace(
                i,
                MailRuleCondition(list[i].kind, sizeKb: int.tryParse(t.trim())),
              ),
            ),
          },
        ),
    ];
  }

  List<Widget> _actionRows(AppColors c) {
    void replace(int i, MailRuleAction next) =>
        setState(() => _actions = [..._actions]..[i] = next);

    return [
      for (var i = 0; i < _actions.length; i++)
        _Row(
          key: ValueKey('action-${_actions[i].kind}'),
          label: mailRuleActionLabel(
            _actions[i].kind,
            google: widget.google,
            local: !widget.capabilities.runsOnServer,
          ),
          onRemove: () => setState(() => _actions = [..._actions]..removeAt(i)),
          child: switch (_actions[i].kind.valueType) {
            MailRuleActionValueType.none => null,
            MailRuleActionValueType.folder => _Dropdown<String>(
              value: _actions[i].folderId,
              hint: widget.google ? 'Choose a label' : 'Choose a folder',
              items: [
                // A folder the picker does not know (deleted, or a list that
                // failed to load) is still listed — a DropdownButton whose
                // value is missing from its own items throws.
                if (_actions[i].folderId != null &&
                    _folderById(_actions[i].folderId) == null)
                  DropdownMenuItem(
                    value: _actions[i].folderId,
                    child: Text(
                      widget.google ? '(unknown label)' : '(unknown folder)',
                    ),
                  ),
                for (final f in widget.folders)
                  DropdownMenuItem(
                    value: f.id,
                    child: Text(f.displayName, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) => replace(
                i,
                MailRuleAction(_actions[i].kind, folderId: id),
              ),
            ),
            MailRuleActionValueType.importance => _Dropdown<MailRuleImportance>(
              value: _actions[i].importance,
              items: [
                for (final v in MailRuleImportance.values)
                  if (widget.capabilities.markImportanceValues.contains(v))
                    DropdownMenuItem(
                      value: v,
                      child: Text(
                        _importanceLabel(
                          v,
                          google: widget.google,
                          asAction: true,
                        ),
                      ),
                    ),
              ],
              onChanged: (v) => replace(
                i,
                MailRuleAction(_actions[i].kind, importance: v),
              ),
            ),
            MailRuleActionValueType.addresses => _textField(
              c,
              initial: _actions[i].addresses.join('; '),
              hint: 'name@example.com; another@example.com',
              onChanged: (t) => replace(
                i,
                MailRuleAction(_actions[i].kind, addresses: _split(t)),
              ),
            ),
          },
        ),
    ];
  }

  /// Alternatives are separated with `;`, Outlook's own separator — a comma
  /// is common inside a phrase someone wants to match.
  static List<String> _split(String text) => text
      .split(';')
      .map((v) => v.trim())
      .where((v) => v.isNotEmpty)
      .toList();

  Widget _sectionLabel(AppColors c, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: TextStyle(color: c.textSecondary, fontSize: 13)),
  );

  Widget _textField(
    AppColors c, {
    TextEditingController? controller,
    String? initial,
    required String hint,
    bool number = false,
    ValueChanged<String>? onChanged,
  }) {
    return SizedBox(
      height: 32,
      child: TextFormField(
        controller: controller,
        initialValue: controller == null ? initial : null,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        style: TextStyle(color: c.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: c.textMuted, fontSize: 12),
          isDense: true,
          filled: true,
          fillColor: c.surfaceBase,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: c.separatorStrong),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: c.separatorStrong),
          ),
        ),
        onChanged: (t) {
          onChanged?.call(t);
          // The name field has no other way to refresh the Save state.
          if (controller != null) setState(() {});
        },
      ),
    );
  }

  Widget _addMenu<T>({
    required String label,
    required List<T> options,
    required String Function(T) labelOf,
    required ValueChanged<T> onSelected,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<T>(
        enabled: options.isNotEmpty && !_saving,
        tooltip: '',
        onSelected: onSelected,
        itemBuilder: (_) => [
          for (final o in options)
            PopupMenuItem(
              value: o,
              height: 36,
              child: Text(labelOf(o), style: const TextStyle(fontSize: 13)),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_rounded,
                size: 16,
                color: options.isEmpty ? context.colors.textMuted : AppColors.accent,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: options.isEmpty ? context.colors.textMuted : AppColors.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A condition or action: its label, the value it needs if any, and a remove
/// button. Stacks the value under the label on a narrow screen.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.label,
    required this.child,
    required this.onRemove,
  });

  final String label;
  final Widget? child;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final labelText = Text(
      label,
      style: TextStyle(color: c.textPrimary, fontSize: 13),
    );
    final remove = IconButton(
      tooltip: 'Remove',
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      onPressed: onRemove,
      icon: Icon(Icons.close_rounded, color: c.textMuted),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (child == null) {
            return Row(children: [Expanded(child: labelText), remove]);
          }
          if (constraints.maxWidth < 440) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [Expanded(child: labelText), remove]),
                child!,
              ],
            );
          }
          return Row(
            children: [
              SizedBox(width: 200, child: labelText),
              const SizedBox(width: 8),
              Expanded(child: child!),
              remove,
            ],
          );
        },
      ),
    );
  }
}

// ─── Shared bits (duplicated from the Out of Office page, the house style) ─

class _AccountPicker extends StatelessWidget {
  const _AccountPicker();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<AccountCubit, AccountState>(
      builder: (context, accountState) {
        if (accountState is! AccountsLoaded ||
            accountState.accounts.length < 2) {
          return const SizedBox.shrink();
        }
        return BlocBuilder<MailRulesCubit, MailRulesState>(
          builder: (context, state) {
            final ids = accountState.accounts.map((a) => a.id).toList();
            return Row(
              children: [
                Text(
                  'Account',
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                ),
                const Spacer(),
                SizedBox(
                  width: 280,
                  child: _Dropdown<String>(
                    value: ids.contains(state.accountId)
                        ? state.accountId
                        : null,
                    items: [
                      for (final a in accountState.accounts)
                        DropdownMenuItem(
                          value: a.id,
                          child: Text(
                            a.emailAddress,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: state.busy
                        ? null
                        : (id) {
                            if (id != null) {
                              context.read<MailRulesCubit>().load(id);
                            }
                          },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          hint: hint == null
              ? null
              : Text(hint!, style: TextStyle(color: c.textMuted, fontSize: 13)),
          dropdownColor: c.surfacePanel,
          style: TextStyle(color: c.textSecondary, fontSize: 13),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.isError = false});

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = isError ? Colors.redAccent : c.textMuted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }
}
