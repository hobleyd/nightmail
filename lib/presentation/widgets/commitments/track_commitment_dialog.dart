import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/commitment.dart';
import '../../../domain/entities/email.dart';
import '../adaptive_alert_dialog.dart';

/// What the user chose when tracking a message by hand.
typedef TrackCommitmentChoice = ({CommitmentKind kind, CommitmentDue due});

/// The Commitments pane section a kind is listed under — for a confirmation
/// that tells the user where to look.
String commitmentSectionTitle(CommitmentKind kind) => switch (kind) {
      CommitmentKind.iOwe => 'You owe',
      CommitmentKind.theyOweMe => 'Waiting on',
      CommitmentKind.needsAction => 'Needs a decision',
    };

/// "Track this message": the two kinds a message of this direction can be,
/// and a coarse due reading, for `TrackCommitment`.
///
/// A received message is either something *I* must act on or a promise *they*
/// made; a sent one is a promise I made or something I asked for. The model
/// reads the same two per direction, so the ledger stays consistent whoever
/// filed the row.
class TrackCommitmentDialog extends StatefulWidget {
  const TrackCommitmentDialog({
    super.key,
    required this.email,
    required this.outgoing,
  });

  final Email email;

  /// Whether the account holder sent the message.
  final bool outgoing;

  /// Resolves to the choice, or null when cancelled.
  static Future<TrackCommitmentChoice?> show(
    BuildContext context, {
    required Email email,
    required bool outgoing,
  }) {
    return showDialog<TrackCommitmentChoice>(
      context: context,
      builder: (_) => TrackCommitmentDialog(email: email, outgoing: outgoing),
    );
  }

  /// The kinds offered for a message of this direction, first one default.
  static List<CommitmentKind> kindsFor({required bool outgoing}) => outgoing
      ? const [CommitmentKind.iOwe, CommitmentKind.theyOweMe]
      : const [CommitmentKind.needsAction, CommitmentKind.theyOweMe];

  static String kindTitle(CommitmentKind kind, {required bool outgoing}) =>
      switch (kind) {
        CommitmentKind.iOwe => 'I owe them',
        CommitmentKind.needsAction => 'Needs my action',
        CommitmentKind.theyOweMe => 'Waiting on them',
      };

  static String kindDetail(CommitmentKind kind, {required bool outgoing}) =>
      switch (kind) {
        CommitmentKind.iOwe => 'I promised to do or send something.',
        CommitmentKind.needsAction =>
          'They are waiting on me to act, decide or reply.',
        CommitmentKind.theyOweMe => outgoing
            ? 'I asked them for something.'
            : 'They promised to do or send something.',
      };

  static String dueLabel(CommitmentDue due) => switch (due) {
        CommitmentDue.today => 'Today',
        CommitmentDue.thisWeek => 'This week',
        CommitmentDue.later => 'Later',
        CommitmentDue.none => 'No deadline',
      };

  @override
  State<TrackCommitmentDialog> createState() => _TrackCommitmentDialogState();
}

class _TrackCommitmentDialogState extends State<TrackCommitmentDialog> {
  late CommitmentKind _kind =
      TrackCommitmentDialog.kindsFor(outgoing: widget.outgoing).first;
  CommitmentDue _due = CommitmentDue.thisWeek;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final who = widget.outgoing
        ? (widget.email.toRecipients.isEmpty
            ? null
            : widget.email.toRecipients.first.displayName)
        : widget.email.from.displayName;
    return AdaptiveAlertDialog(
      title: const Text('Track this message', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                if (who != null && who.isNotEmpty) who,
                if (widget.email.subject.trim().isNotEmpty)
                  widget.email.subject.trim(),
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            for (final kind
                in TrackCommitmentDialog.kindsFor(outgoing: widget.outgoing))
              _KindRow(
                title: TrackCommitmentDialog.kindTitle(kind,
                    outgoing: widget.outgoing),
                detail: TrackCommitmentDialog.kindDetail(kind,
                    outgoing: widget.outgoing),
                selected: _kind == kind,
                onTap: () => setState(() => _kind = kind),
              ),
            const SizedBox(height: 12),
            Text(
              'DUE',
              style: TextStyle(
                color: c.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final due in CommitmentDue.values)
                  ChoiceChip(
                    label: Text(TrackCommitmentDialog.dueLabel(due)),
                    selected: _due == due,
                    onSelected: (_) => setState(() => _due = due),
                    labelStyle: TextStyle(
                      fontSize: 12,
                      color: _due == due ? AppColors.accent : c.textSecondary,
                    ),
                    selectedColor: AppColors.accent.withAlpha(28),
                    backgroundColor: c.surfaceBase,
                    side: BorderSide(
                      color: _due == due ? AppColors.accent : c.separatorStrong,
                    ),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop((kind: _kind, due: _due)),
          child: const Text('Track'),
        ),
      ],
    );
  }
}

class _KindRow extends StatelessWidget {
  const _KindRow({
    required this.title,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 16,
                color: selected ? AppColors.accent : c.textMuted,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    detail,
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
