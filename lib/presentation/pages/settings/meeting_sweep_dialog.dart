import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/calendar_event.dart';
import '../../../injection_container.dart';
import '../../blocs/out_of_office/meeting_sweep_cubit.dart';
import '../../blocs/out_of_office/meeting_sweep_state.dart';

/// Offered right after Out of Office is switched on and saved: lists the
/// meetings the account is either attending or running during that window and
/// lets the user decline/cancel the ones they pick before anything is sent.
///
/// Only ever shown when the account being edited is the one currently active
/// elsewhere in the app — see [MeetingSweepCubit] for why the calendar side
/// cannot safely act on any other account.
Future<void> showMeetingSweepDialog(
  BuildContext context, {
  required String accountId,
  required DateTime start,
  required DateTime end,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => BlocProvider<MeetingSweepCubit>(
      create: (_) => sl<MeetingSweepCubit>()
        ..load(accountId: accountId, start: start, end: end),
      child: const _MeetingSweepDialog(),
    ),
  );
}

class _MeetingSweepDialog extends StatelessWidget {
  const _MeetingSweepDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Meetings while you are away'),
      content: SizedBox(
        width: 480,
        child: BlocBuilder<MeetingSweepCubit, MeetingSweepState>(
          builder: (context, state) => _body(context, state),
        ),
      ),
      actions: _actions(context),
    );
  }

  Widget _body(BuildContext context, MeetingSweepState state) {
    switch (state.status) {
      case MeetingSweepStatus.idle:
      case MeetingSweepStatus.loading:
        return const SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        );
      case MeetingSweepStatus.accountMismatch:
        return const _Message(
          icon: Icons.info_outline_rounded,
          text:
              'This account is not the one currently active in the app, so '
              'meetings cannot be checked from here. Switch to this account '
              'first and turn Out of Office on again to use this.',
        );
      case MeetingSweepStatus.error:
        return _Message(
          icon: Icons.error_outline_rounded,
          text: state.errorMessage ?? 'Could not load your calendar.',
          isError: true,
        );
      case MeetingSweepStatus.empty:
        return const _Message(
          icon: Icons.check_circle_outline_rounded,
          text: 'No meetings need a decision during this time.',
        );
      case MeetingSweepStatus.ready:
      case MeetingSweepStatus.applying:
        return _list(context, state);
      case MeetingSweepStatus.done:
        return _results(context, state);
    }
  }

  Widget _list(BuildContext context, MeetingSweepState state) {
    final c = context.colors;
    final cubit = context.read<MeetingSweepCubit>();
    final applying = state.status == MeetingSweepStatus.applying;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pick which ones to hand off before you go.',
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (state.accepted.isNotEmpty) ...[
              _SectionHeader(
                label: 'Meetings you accepted (${state.accepted.length})',
              ),
              for (final e in state.accepted)
                _MeetingRow(
                  event: e,
                  selected: state.selectedIds.contains(e.id),
                  subtitle: 'Decline',
                  enabled: !applying,
                  onChanged: () => cubit.toggle(e.id),
                ),
              const SizedBox(height: 12),
            ],
            if (state.organized.isNotEmpty) ...[
              _SectionHeader(
                label: 'Meetings you organize (${state.organized.length})',
              ),
              for (final e in state.organized)
                _MeetingRow(
                  event: e,
                  selected: state.selectedIds.contains(e.id),
                  subtitle:
                      'Cancel — notifies '
                      '${e.attendees.length} '
                      '${e.attendees.length == 1 ? 'attendee' : 'attendees'}',
                  isDestructive: true,
                  enabled: !applying,
                  onChanged: () => cubit.toggle(e.id),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _results(BuildContext context, MeetingSweepState state) {
    final c = context.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              state.failedCount == 0
                  ? 'Done.'
                  : '${state.failedCount} could not be updated.',
              style: TextStyle(
                color: state.failedCount == 0 ? c.textSecondary : Colors.redAccent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            for (final r in state.results)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      r.succeeded
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 16,
                      color: r.succeeded ? c.textMuted : Colors.redAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.succeeded
                            ? '${r.action == MeetingSweepAction.cancel ? 'Cancelled' : 'Declined'}: ${r.subject}'
                            : '${r.subject}: ${r.errorMessage ?? 'failed'}',
                        style: TextStyle(color: c.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    return [
      BlocBuilder<MeetingSweepCubit, MeetingSweepState>(
        builder: (context, state) {
          final cubit = context.read<MeetingSweepCubit>();
          switch (state.status) {
            case MeetingSweepStatus.ready:
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Not now'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: state.selectedTotal == 0
                        ? null
                        : cubit.confirm,
                    child: Text(_confirmLabel(state)),
                  ),
                ],
              );
            case MeetingSweepStatus.applying:
              return const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            case MeetingSweepStatus.done:
            case MeetingSweepStatus.empty:
            case MeetingSweepStatus.accountMismatch:
            case MeetingSweepStatus.error:
              return TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              );
            case MeetingSweepStatus.idle:
            case MeetingSweepStatus.loading:
              return TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              );
          }
        },
      ),
    ];
  }

  String _confirmLabel(MeetingSweepState state) {
    final parts = <String>[];
    if (state.selectedAcceptedCount > 0) {
      parts.add('Decline ${state.selectedAcceptedCount}');
    }
    if (state.selectedOrganizedCount > 0) {
      parts.add('Cancel ${state.selectedOrganizedCount}');
    }
    return parts.isEmpty ? 'Confirm' : parts.join(' & ');
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        label,
        style: TextStyle(
          color: c.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MeetingRow extends StatelessWidget {
  const _MeetingRow({
    required this.event,
    required this.selected,
    required this.subtitle,
    required this.onChanged,
    this.isDestructive = false,
    this.enabled = true,
  });

  final CalendarEvent event;
  final bool selected;
  final String subtitle;
  final VoidCallback onChanged;
  final bool isDestructive;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: enabled ? onChanged : null,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: selected,
              onChanged: enabled ? (_) => onChanged() : null,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.subject.isEmpty ? '(No subject)' : event.subject,
                      style: TextStyle(color: c.textPrimary, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _timeLabel(event),
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: isDestructive ? Colors.redAccent : c.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeLabel(CalendarEvent event) {
    final date = DateFormat('EEE, MMM d').format(event.start);
    if (event.isAllDay) return '$date · All day';
    final start = DateFormat('h:mm a').format(event.start);
    final end = DateFormat('h:mm a').format(event.end);
    return '$date · $start – $end';
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.isError = false});

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = isError ? Colors.redAccent : c.textMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
