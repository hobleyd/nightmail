import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/platform/touch_metrics.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/commitment.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/commitments/commitments_cubit.dart';
import '../blocs/commitments/commitments_state.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/home/home_cubit.dart';
import '../../domain/entities/workload_forecast.dart';
import '../../domain/usecases/commitments/run_commitments_agent.dart';
import '../../injection_container.dart';
import '../blocs/commitments/commitments_agent_cubit.dart';
import '../blocs/mail_poller/mail_poller_cubit.dart';
import '../widgets/commitments/commitments_assistant.dart';
import '../widgets/commitments/rebalance_dialog.dart';
import '../widgets/commitments/schedule_commitment_dialog.dart';
import '../widgets/commitments/workload_strip.dart';
import 'settings_page.dart';

/// The Commitments pane: mail, calendar and tasks read as one stream of
/// obligations.
///
/// Four sections, top to bottom — **Today** (today's meetings, how many tasks
/// fall due, and every commitment due or overdue), **You owe** (promises made
/// in sent mail), **Waiting on** (what others owe, with how long it has been),
/// and **Needs a decision** (received mail still awaiting action, against the
/// count of mail that needs none). The rows come from `CommitmentsCubit`,
/// which has a System One model read the account's recent Sent and Inbox mail;
/// tapping a row opens its message in the reading pane, like a task's linked
/// mail does.
///
/// Docked beside the reading pane on desktop (`HomeView.commitments`), pushed
/// as a route on a phone (`useBackNavigation`), exactly like the Tasks pane —
/// and, from a double-click on the footer button, in its own screen-sized
/// window (`CommitmentsWindowApp`). The layout follows the width it is given:
/// a single scrolling column in a side pane, a four-column board once there
/// is room for one ([kBoardMinWidth]).
class CommitmentsDayPanel extends StatefulWidget {
  const CommitmentsDayPanel({
    super.key,
    required this.onClose,
    this.useBackNavigation = false,
    this.onOpenEmail,
  });

  final VoidCallback onClose;

  /// True when the panel was pushed as a route rather than docked as a side
  /// pane — the mobile shell. It then dismisses through a leading back arrow,
  /// like the reading pane, instead of a trailing close button.
  final bool useBackNavigation;

  /// Overrides how a row's message is opened. By default it goes to the
  /// reading pane of the window the panel is in; the detached window has no
  /// reading pane and opens an email-view window instead.
  final ValueChanged<Commitment>? onOpenEmail;

  /// The width from which the sections are laid out side by side as a board
  /// rather than stacked. Four columns of cards need about this much to read
  /// well; a screen-sized window has it, the side pane never does.
  static const double kBoardMinWidth = 960;

  @override
  State<CommitmentsDayPanel> createState() => _CommitmentsDayPanelState();
}

class _CommitmentsDayPanelState extends State<CommitmentsDayPanel> {
  late final CommitmentsCubit _cubit;

  /// Natural-language control: its own chat cubit, fed snapshots by
  /// [_cubit] and asking it to reload once a turn's tools have run. Created
  /// here (not provided from outside) so every host of the pane — docked,
  /// phone route, detached window — gets one without extra wiring.
  late final CommitmentsAgentCubit _agent;
  StreamSubscription<void>? _pollSub;
  StreamSubscription<void>? _accountSub;
  int? _lastPollGeneration;
  String? _lastAccountId;

  @override
  void initState() {
    super.initState();
    _cubit = context.read<CommitmentsCubit>();
    _agent = CommitmentsAgentCubit(
      runAgent: sl<RunCommitmentsAgent>(),
      snapshot: _cubit.agentSnapshot,
      onChanged: _cubit.reloadLedger,
    );
    // A completed poll cycle may have brought new mail: scan it. An account
    // switch means a different ledger: reload. Both blocs are optional —
    // a detached window may provide neither — so a missing one is ignored.
    try {
      final poller = context.read<MailPollerCubit>();
      _lastPollGeneration = poller.state.pollGeneration;
      _pollSub = poller.stream.listen((s) {
        if (s.pollGeneration == _lastPollGeneration) return;
        _lastPollGeneration = s.pollGeneration;
        if (mounted) unawaited(_cubit.scan());
      });
    } catch (_) {}
    try {
      final accounts = context.read<AccountCubit>();
      final current = accounts.state;
      if (current is AccountsLoaded) _lastAccountId = current.activeAccount.id;
      _accountSub = accounts.stream.listen((s) {
        if (s is! AccountsLoaded) return;
        final id = s.activeAccount.id;
        if (id == _lastAccountId) return;
        _lastAccountId = id;
        if (mounted) unawaited(_cubit.load());
      });
    } catch (_) {}
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_cubit.load());
    });
  }

  @override
  void dispose() {
    _pollSub?.cancel();
    _accountSub?.cancel();
    _agent.close();
    super.dispose();
  }

  /// Opens the commitment's message in the reading pane and narrows the email
  /// list to its thread, so it arrives with its context — the same path a
  /// task's linked email takes. In a detached window there is no reading pane
  /// (no EmailDetailBloc), so fall back to a hint.
  void _openEmail(Commitment commitment) {
    final override = widget.onOpenEmail;
    if (override != null) {
      override(commitment);
      return;
    }
    try {
      final detailBloc = context.read<EmailDetailBloc>();
      final listBloc = context.read<EmailListBloc>();
      final homeCubit = context.read<HomeCubit>();

      detailBloc.add(EmailDetailLoadRequested(emailId: commitment.emailId));
      listBloc.add(EmailListThreadFocusRequested(emailId: commitment.emailId));
      homeCubit.selectEmail(commitment.emailId);
      // On a phone the pane covers the mail; step back so it can be seen.
      if (widget.useBackNavigation) widget.onClose();
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Open Commitments in the main window to view the message.',
          ),
        ),
      );
    }
  }

  void _openTasks() {
    try {
      context.read<HomeCubit>().showTasks();
      if (widget.useBackNavigation) widget.onClose();
    } catch (_) {}
  }

  /// Blocks time for [commitment]: asks the cubit for a suggestion from the
  /// coming week's calendar, lets the user move it in the scheduling dialog
  /// (a day list here, a week grid in the detached window), then books it.
  Future<void> _schedule(Commitment commitment) async {
    final suggestion = await _cubit.suggestTimeBlock(commitment);
    if (!mounted) return;
    final scheduled = await ScheduleCommitmentDialog.show(
      context,
      commitment: commitment,
      suggestion: suggestion,
      suggester: _cubit.suggester,
      onSchedule: (start, end) =>
          _cubit.schedule(commitment, start: start, end: end),
    );
    if (scheduled && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Time blocked for ${commitment.counterpart.displayName}.',
          ),
        ),
      );
    }
  }

  /// Shows the moves "Future Me" proposes for an overloaded day and applies
  /// the ones the user keeps.
  Future<void> _rebalance(RebalancePlan plan) async {
    final applied = await RebalanceDialog.show(
      context,
      plan: plan,
      onApply: _cubit.applyMoves,
    );
    if (applied > 0 && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Moved $applied ${applied == 1 ? 'block' : 'blocks'} off '
            '${DateFormat('EEEE').format(plan.day.day)}.',
          ),
        ),
      );
    }
  }

  /// Puts the slot's suggested commitment into a gap that opened in today.
  Future<void> _fillSlot(OpenSlot slot) async {
    final ok = await _cubit.fillSlot(slot);
    if (ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            '${slot.suggestion?.counterpart.displayName ?? 'Commitment'} '
            'scheduled for ${DateFormat.jm().format(slot.start)}.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocProvider<CommitmentsAgentCubit>.value(
      value: _agent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The assistant sits under the ledger in a pane and takes its own
          // column in the board, so the board body hosts it when wide.
          final wide =
              constraints.maxWidth >= CommitmentsDayPanel.kBoardMinWidth;
          return ColoredBox(
      color: c.surfacePanel,
      child: Column(
        children: [
          BlocBuilder<CommitmentsCubit, CommitmentsState>(
            buildWhen: (p, n) => p.status != n.status,
            builder: (context, state) => _Header(
              onClose: widget.onClose,
              useBackNavigation: widget.useBackNavigation,
              scanning: state.status == CommitmentsStatus.scanning,
              onRefresh: () => unawaited(_cubit.scan()),
            ),
          ),
          Divider(height: 1, color: c.separatorStrong),
          Expanded(
            child: BlocBuilder<CommitmentsCubit, CommitmentsState>(
              builder: (context, state) {
                switch (state.status) {
                  case CommitmentsStatus.initial:
                  case CommitmentsStatus.loading:
                    return Center(
                      child: CircularProgressIndicator(
                        color: AppColors.accent,
                        strokeWidth: 2,
                      ),
                    );
                  case CommitmentsStatus.error:
                    return _ErrorView(
                      message: state.message ?? 'Could not load commitments',
                    );
                  case CommitmentsStatus.scanning:
                  case CommitmentsStatus.loaded:
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >=
                            CommitmentsDayPanel.kBoardMinWidth;
                        return wide
                            ? _BoardBody(
                                state: state,
                                onOpen: _openEmail,
                                onOpenTasks: _openTasks,
                                onDone: (c) => unawaited(_cubit.markDone(c.id)),
                                onDismiss: (c) =>
                                    unawaited(_cubit.dismiss(c.id)),
                                onSchedule: (c) => unawaited(_schedule(c)),
                                onRebalance: (p) => unawaited(_rebalance(p)),
                                onFillSlot: (s) => unawaited(_fillSlot(s)),
                              )
                            : _LoadedBody(
                                state: state,
                                onOpen: _openEmail,
                                onOpenTasks: _openTasks,
                                onDone: (c) => unawaited(_cubit.markDone(c.id)),
                                onDismiss: (c) =>
                                    unawaited(_cubit.dismiss(c.id)),
                                onSchedule: (c) => unawaited(_schedule(c)),
                                onRebalance: (p) => unawaited(_rebalance(p)),
                                onFillSlot: (s) => unawaited(_fillSlot(s)),
                              );
                      },
                    );
                }
              },
            ),
          ),
          if (!wide) const CommitmentsAssistant(compact: true),
        ],
      ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.onClose,
    required this.scanning,
    required this.onRefresh,
    this.useBackNavigation = false,
  });

  final VoidCallback onClose;
  final bool scanning;
  final VoidCallback onRefresh;
  final bool useBackNavigation;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: touchRowHeight(48),
      child: Padding(
        padding: useBackNavigation
            ? const EdgeInsets.fromLTRB(4, 0, 8, 0)
            : const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(
          children: [
            if (useBackNavigation) ...[
              IconButton(
                icon: Icon(Icons.arrow_back_ios_new_rounded,
                    size: touchIcon(16), color: c.textMuted),
                tooltip: 'Back',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: touchTarget(28),
                  minHeight: touchTarget(28),
                ),
                onPressed: onClose,
              ),
              const SizedBox(width: 4),
            ],
            Icon(Icons.handshake_outlined,
                size: touchIcon(16), color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Commitments',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            if (scanning)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: c.textMuted,
                  ),
                ),
              )
            else
              IconButton(
                icon: Icon(Icons.refresh_rounded,
                    size: touchIcon(16), color: c.textMuted),
                tooltip: 'Check new mail for commitments',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: touchTarget(28),
                  minHeight: touchTarget(28),
                ),
                onPressed: onRefresh,
              ),
            if (!useBackNavigation)
              IconButton(
                icon:
                    Icon(Icons.close, size: touchIcon(16), color: c.textMuted),
                tooltip: 'Close',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: touchTarget(28),
                  minHeight: touchTarget(28),
                ),
                onPressed: onClose,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

class _LoadedBody extends StatelessWidget {
  const _LoadedBody({
    required this.state,
    required this.onOpen,
    required this.onOpenTasks,
    required this.onDone,
    required this.onDismiss,
    required this.onSchedule,
    required this.onRebalance,
    required this.onFillSlot,
  });

  final CommitmentsState state;
  final ValueChanged<Commitment> onOpen;
  final VoidCallback onOpenTasks;
  final ValueChanged<Commitment> onDone;
  final ValueChanged<Commitment> onDismiss;
  final ValueChanged<Commitment> onSchedule;
  final ValueChanged<RebalancePlan> onRebalance;
  final ValueChanged<OpenSlot> onFillSlot;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dueToday = state.dueTodayAt(now);
    final iOwe = state.iOwe;
    final waitingOn = state.waitingOn;
    final needsAction = state.needsAction;
    final forecast = state.forecast;

    Widget row(Commitment c) => _CommitmentRow(
          commitment: c,
          now: now,
          onTap: () => onOpen(c),
          onDone: () => onDone(c),
          onDismiss: () => onDismiss(c),
          onSchedule: () => onSchedule(c),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      children: [
        if (state.needsTriageRoute)
          _SetupCard(message: state.message)
        else ...[
          if (state.message != null) _Notice(text: state.message!),
          _ScanLine(state: state),
        ],
        if (forecast != null)
          WorkloadStrip(
            forecast: forecast,
            wide: false,
            onRebalance: onRebalance,
            onFillSlot: onFillSlot,
          ),
        _Section(
          title: 'Today',
          emptyText: state.todayEvents.isEmpty && state.tasksDueToday == 0
              ? 'Nothing scheduled, nothing due.'
              : null,
          children: [
            for (final e in state.todayEvents) _EventRow(event: e),
            if (state.tasksDueToday > 0)
              _TasksRow(count: state.tasksDueToday, onTap: onOpenTasks),
            for (final c in dueToday) row(c),
          ],
        ),
        _Section(
          title: 'You owe',
          emptyText: iOwe.isEmpty ? 'No open promises.' : null,
          children: [for (final c in iOwe) row(c)],
        ),
        _Section(
          title: 'Waiting on',
          emptyText: waitingOn.isEmpty ? 'Nobody owes you anything.' : null,
          children: [for (final c in waitingOn) row(c)],
        ),
        _Section(
          title: 'Needs a decision',
          emptyText: needsAction.isEmpty ? 'Nothing waiting on you.' : null,
          footer: state.inboxScanned == 0
              ? null
              : '${needsAction.length} '
                  '${needsAction.length == 1 ? 'email needs' : 'emails need'} '
                  'action · ${state.inboxNoActionCount} '
                  '${state.inboxNoActionCount == 1 ? "doesn't" : "don't"}',
          children: [for (final c in needsAction) row(c)],
        ),
      ],
    );
  }
}

/// The status line under the header: what the last scan did, or that one is
/// running.
class _ScanLine extends StatelessWidget {
  const _ScanLine({required this.state});

  final CommitmentsState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final String text;
    if (state.status == CommitmentsStatus.scanning) {
      text = 'Reading new mail…';
    } else if (state.lastScanAt == null) {
      text = 'Not scanned yet.';
    } else {
      final parts = <String>[
        'Checked ${state.lastClassified} new '
            '${state.lastClassified == 1 ? 'email' : 'emails'}',
        if (state.remaining > 0) '${state.remaining} more to go',
        DateFormat.jm().format(state.lastScanAt!),
      ];
      text = parts.join(' · ');
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: TextStyle(color: c.textMuted, fontSize: 11)),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: c.errorBannerBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: c.textSecondary, fontSize: 12)),
    );
  }
}

/// Shown instead of the scan line when Triage has no System One provider: the
/// one setup step the whole pane depends on, with the way there.
class _SetupCard extends StatelessWidget {
  const _SetupCard({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Set up commitment detection',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message ??
                'Route Triage to a System One provider (Jev or Laya-MLX) in '
                    'Settings › AI. It reads your recent mail and lists what '
                    'you owe, what you are waiting on, and what needs a '
                    'decision.',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: () => SettingsDialog.open(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Open AI settings'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.emptyText,
    this.footer,
  });

  final String title;
  final List<Widget> children;

  /// Shown in place of the rows when there are none.
  final String? emptyText;

  /// A summary line under the rows.
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                color: c.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: c.separatorStrong),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: children.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Text(
                      emptyText ?? '',
                      style: TextStyle(color: c.textMuted, fontSize: 12),
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < children.length; i++) ...[
                        if (i > 0) Divider(height: 1, color: c.separator),
                        children[i],
                      ],
                    ],
                  ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Text(
                footer!,
                style: TextStyle(color: c.textMuted, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final time = event.isAllDay
        ? 'All day'
        : DateFormat.jm().format(event.start.toLocal());
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.calendar_month_outlined, size: 14, color: c.textMuted),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(
              time,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              event.subject,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _TasksRow extends StatelessWidget {
  const _TasksRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.checklist_rounded, size: 14, color: c.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$count ${count == 1 ? 'task' : 'tasks'} due today',
                style: TextStyle(color: c.textSecondary, fontSize: 12),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 16, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

class _CommitmentRow extends StatelessWidget {
  const _CommitmentRow({
    required this.commitment,
    required this.now,
    required this.onTap,
    required this.onDone,
    required this.onDismiss,
    required this.onSchedule,
  });

  final Commitment commitment;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onDone;
  final VoidCallback onDismiss;
  final VoidCallback onSchedule;

  IconData get _icon => switch (commitment.kind) {
        CommitmentKind.iOwe => Icons.outbox_outlined,
        CommitmentKind.theyOweMe => Icons.hourglass_bottom_rounded,
        CommitmentKind.needsAction => Icons.reply_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final overdue = commitment.isOverdueAt(now);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              _icon,
              size: 14,
              color: overdue ? AppColors.notification : c.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    commitment.counterpart.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    commitment.subject.isEmpty
                        ? commitment.snippet
                        : commitment.subject,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _DueChip(commitment: commitment, overdue: overdue),
                const SizedBox(height: 2),
                if (commitment.isScheduled)
                  _ScheduledLabel(commitment: commitment)
                else
                  Text(
                    ageLabel(commitment.ageAt(now)),
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
              ],
            ),
            IconButton(
              icon: Icon(
                commitment.isScheduled
                    ? Icons.event_rounded
                    : Icons.event_available_outlined,
                size: 16,
                color: commitment.isScheduled ? AppColors.accent : c.textMuted,
              ),
              tooltip: commitment.isScheduled ? 'Move time block' : 'Schedule time',
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: touchTarget(28),
                minHeight: touchTarget(28),
              ),
              onPressed: onSchedule,
            ),
            IconButton(
              icon: Icon(Icons.check_rounded, size: 16, color: c.textMuted),
              tooltip: 'Done',
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: touchTarget(28),
                minHeight: touchTarget(28),
              ),
              onPressed: onDone,
            ),
            IconButton(
              icon: Icon(Icons.close_rounded, size: 16, color: c.textMuted),
              tooltip: 'Dismiss',
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: touchTarget(28),
                minHeight: touchTarget(28),
              ),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _DueChip extends StatelessWidget {
  const _DueChip({required this.commitment, required this.overdue});

  final Commitment commitment;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final String? label;
    Color color = c.textMuted;
    if (overdue) {
      label = 'Overdue';
      color = AppColors.notification;
    } else {
      switch (commitment.due) {
        case CommitmentDue.today:
          label = 'Today';
          color = AppColors.accent;
        case CommitmentDue.thisWeek:
          label = 'This week';
        case CommitmentDue.later:
          label = 'Later';
        case CommitmentDue.none:
          label = null;
      }
    }
    if (label == null) return const SizedBox(height: 18);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// When a commitment's time block is: `Thu 10:00 AM`.
String scheduledLabel(Commitment c) {
  final start = c.scheduledStart!;
  return '${DateFormat('EEE').format(start)} ${DateFormat.jm().format(start)}';
}

/// The scheduled block, as a small accent label with a calendar glyph.
class _ScheduledLabel extends StatelessWidget {
  const _ScheduledLabel({required this.commitment});

  final Commitment commitment;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.event_rounded, size: 11, color: AppColors.accent),
        const SizedBox(width: 3),
        Text(
          scheduledLabel(commitment),
          style: const TextStyle(
            color: AppColors.accent,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// `2 h`, `3 days`, `2 wk` — how long a commitment has been outstanding.
String ageLabel(Duration age) {
  if (age.isNegative) return 'now';
  if (age.inHours < 1) return '<1 h';
  if (age.inHours < 24) return '${age.inHours} h';
  if (age.inDays < 14) return '${age.inDays} ${age.inDays == 1 ? 'day' : 'days'}';
  if (age.inDays < 60) return '${age.inDays ~/ 7} wk';
  return '${age.inDays ~/ 30} mo';
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textMuted, fontSize: 13),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Board layout — a screen-sized window
// ---------------------------------------------------------------------------

/// The four sections side by side, each a column of cards, for a window wide
/// enough to hold them ([CommitmentsDayPanel.kBoardMinWidth] and up).
///
/// The point of the extra room is that everything is visible at once with
/// nothing to scroll past: the day on the left, the two sides of the ledger in
/// the middle, the inbox decisions on the right. Cards carry what the narrow
/// rows have to drop — the excerpt of what was actually said — and an explicit
/// Open action. On very wide screens the board stops growing at
/// [_maxBoardWidth] and sits centred, so four columns never stretch into
/// unreadable lines.
class _BoardBody extends StatelessWidget {
  const _BoardBody({
    required this.state,
    required this.onOpen,
    required this.onOpenTasks,
    required this.onDone,
    required this.onDismiss,
    required this.onSchedule,
    required this.onRebalance,
    required this.onFillSlot,
  });

  final CommitmentsState state;
  final ValueChanged<Commitment> onOpen;
  final VoidCallback onOpenTasks;
  final ValueChanged<Commitment> onDone;
  final ValueChanged<Commitment> onDismiss;
  final ValueChanged<Commitment> onSchedule;
  final ValueChanged<RebalancePlan> onRebalance;
  final ValueChanged<OpenSlot> onFillSlot;

  static const double _maxBoardWidth = 2100;
  static const double _gutter = 16;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dueToday = state.dueTodayAt(now);
    final iOwe = state.iOwe;
    final waitingOn = state.waitingOn;
    final needsAction = state.needsAction;
    final forecast = state.forecast;

    Widget card(Commitment c) => _CommitmentCard(
          commitment: c,
          now: now,
          onOpen: () => onOpen(c),
          onDone: () => onDone(c),
          onDismiss: () => onDismiss(c),
          onSchedule: () => onSchedule(c),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Status strip: the setup card when Triage has no route, else any
        // warning plus the scan line — left-aligned and width-capped so a
        // single sentence does not run the length of a wide screen.
        Padding(
          padding: const EdgeInsets.fromLTRB(_gutter, 12, _gutter, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: state.needsTriageRoute
                  ? _SetupCard(message: state.message)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (state.message != null) _Notice(text: state.message!),
                        _ScanLine(state: state),
                      ],
                    ),
            ),
          ),
        ),
        // The week ahead, full width above the columns: the forecast is the
        // one thing on this screen that is about the days to come rather
        // than the items themselves.
        if (forecast != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(_gutter, 10, _gutter, 0),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxBoardWidth),
                child: WorkloadStrip(
                  forecast: forecast,
                  wide: true,
                  onRebalance: onRebalance,
                  onFillSlot: onFillSlot,
                ),
              ),
            ),
          ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxBoardWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(_gutter, 4, _gutter, _gutter),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _BoardColumn(
                        title: 'Today',
                        icon: Icons.today_rounded,
                        count: dueToday.length +
                            state.todayEvents.length +
                            (state.tasksDueToday > 0 ? 1 : 0),
                        emptyText: 'Nothing scheduled, nothing due.',
                        children: [
                          for (final e in state.todayEvents)
                            _BoardEventTile(event: e),
                          if (state.tasksDueToday > 0)
                            _BoardTasksTile(
                              count: state.tasksDueToday,
                              onTap: onOpenTasks,
                            ),
                          for (final c in dueToday) card(c),
                        ],
                      ),
                    ),
                    const SizedBox(width: _gutter),
                    Expanded(
                      child: _BoardColumn(
                        title: 'You owe',
                        icon: Icons.outbox_outlined,
                        count: iOwe.length,
                        emptyText: 'No open promises.',
                        children: [for (final c in iOwe) card(c)],
                      ),
                    ),
                    const SizedBox(width: _gutter),
                    Expanded(
                      child: _BoardColumn(
                        title: 'Waiting on',
                        icon: Icons.hourglass_bottom_rounded,
                        count: waitingOn.length,
                        emptyText: 'Nobody owes you anything.',
                        children: [for (final c in waitingOn) card(c)],
                      ),
                    ),
                    const SizedBox(width: _gutter),
                    Expanded(
                      child: _BoardColumn(
                        title: 'Needs a decision',
                        icon: Icons.reply_rounded,
                        count: needsAction.length,
                        emptyText: 'Nothing waiting on you.',
                        footer: state.inboxScanned == 0
                            ? null
                            : '${needsAction.length} '
                                '${needsAction.length == 1 ? 'email needs' : 'emails need'} '
                                'action · ${state.inboxNoActionCount} '
                                '${state.inboxNoActionCount == 1 ? "doesn't" : "don't"}',
                        children: [for (final c in needsAction) card(c)],
                      ),
                    ),
                    const SizedBox(width: _gutter),
                    // Natural-language control gets a column of its own
                    // here; in the narrow pane it sits under the ledger.
                    const SizedBox(
                      width: 340,
                      child: CommitmentsAssistant(compact: false),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One column of the board: a header with the section's icon, name and count,
/// then its cards in their own scroll view, so a long Needs-a-decision list
/// never pushes Today off the screen.
class _BoardColumn extends StatelessWidget {
  const _BoardColumn({
    required this.title,
    required this.icon,
    required this.count,
    required this.children,
    required this.emptyText,
    this.footer,
  });

  final String title;
  final IconData icon;
  final int count;
  final List<Widget> children;
  final String emptyText;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
            child: Row(
              children: [
                Icon(icon, size: 16, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                if (count > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.surfaceBase,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: c.separatorStrong),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: c.separatorStrong),
          Expanded(
            child: children.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      emptyText,
                      style: TextStyle(color: c.textMuted, fontSize: 12),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: children.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => children[i],
                  ),
          ),
          if (footer != null) ...[
            Divider(height: 1, color: c.separatorStrong),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Text(
                footer!,
                style: TextStyle(color: c.textMuted, fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A commitment as a card: who, the subject, what was said, and when — with
/// Open, Done and Dismiss along the bottom. The whole card opens the message.
class _CommitmentCard extends StatelessWidget {
  const _CommitmentCard({
    required this.commitment,
    required this.now,
    required this.onOpen,
    required this.onDone,
    required this.onDismiss,
    required this.onSchedule,
  });

  final Commitment commitment;
  final DateTime now;
  final VoidCallback onOpen;
  final VoidCallback onDone;
  final VoidCallback onDismiss;
  final VoidCallback onSchedule;

  IconData get _icon => switch (commitment.kind) {
        CommitmentKind.iOwe => Icons.outbox_outlined,
        CommitmentKind.theyOweMe => Icons.hourglass_bottom_rounded,
        CommitmentKind.needsAction => Icons.reply_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final overdue = commitment.isOverdueAt(now);
    final snippet = commitment.snippet.trim();
    final showSnippet =
        snippet.isNotEmpty && snippet != commitment.subject.trim();
    return Material(
      color: c.surfaceBase,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          decoration: BoxDecoration(
            border: Border.all(
              color: overdue
                  ? AppColors.notification.withAlpha(120)
                  : c.separatorStrong,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _icon,
                    size: 14,
                    color: overdue ? AppColors.notification : c.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      commitment.counterpart.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _DueChip(commitment: commitment, overdue: overdue),
                ],
              ),
              if (commitment.subject.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  commitment.subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                ),
              ],
              if (showSnippet) ...[
                const SizedBox(height: 3),
                Text(
                  snippet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textMuted, fontSize: 12, height: 1.3),
                ),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    ageLabel(commitment.ageAt(now)),
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
                  if (commitment.isScheduled) ...[
                    Text(
                      '  ·  ',
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                    _ScheduledLabel(commitment: commitment),
                  ],
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.open_in_new_rounded,
                        size: 15, color: c.textMuted),
                    tooltip: 'Open message',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: onOpen,
                  ),
                  IconButton(
                    icon: Icon(
                      commitment.isScheduled
                          ? Icons.event_rounded
                          : Icons.event_available_outlined,
                      size: 15,
                      color: commitment.isScheduled
                          ? AppColors.accent
                          : c.textMuted,
                    ),
                    tooltip: commitment.isScheduled
                        ? 'Move time block'
                        : 'Schedule time',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: onSchedule,
                  ),
                  IconButton(
                    icon: Icon(Icons.check_rounded, size: 16, color: c.textMuted),
                    tooltip: 'Done',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: onDone,
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, size: 16, color: c.textMuted),
                    tooltip: 'Dismiss',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: onDismiss,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A meeting in the board's Today column: the time in a fixed gutter, the
/// subject beside it, and the location when there is one.
class _BoardEventTile extends StatelessWidget {
  const _BoardEventTile({required this.event});

  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final start = event.start.toLocal();
    final end = event.end.toLocal();
    final time = event.isAllDay
        ? 'All day'
        : '${DateFormat.jm().format(start)} – ${DateFormat.jm().format(end)}';
    final location = event.location?.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.calendar_month_outlined, size: 14, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  time,
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  event.subject,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                ),
                if (location != null && location.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The tasks-due count as a board tile; tapping it opens the Tasks view.
class _BoardTasksTile extends StatelessWidget {
  const _BoardTasksTile({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            border: Border.all(color: c.separatorStrong),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.checklist_rounded, size: 14, color: c.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$count ${count == 1 ? 'task' : 'tasks'} due today',
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 16, color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
