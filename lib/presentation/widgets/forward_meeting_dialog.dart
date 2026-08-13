import 'package:flutter/material.dart';
// fpdart declares its own `State` monad, which collides with Flutter's.
import 'package:fpdart/fpdart.dart' hide State;

import '../../core/error/failures.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/meeting_forward.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';
import 'recipient_input_field.dart';

/// Asks who to forward a meeting to, sends it, and reports which of the two
/// ways it went — see [MeetingForwardMode].
///
/// Shared by the two places a meeting can be opened from: the invitation email
/// in the reading pane and the read-only event form for somebody else's
/// meeting. Both hand it a [send] closure rather than a meeting, because the
/// two identify the same meeting differently (a message id versus an event id)
/// and neither can be derived from the other here.
///
/// It reports the outcome itself rather than popping with a result for the
/// caller to word, because the two outcomes need to be told apart carefully and
/// saying it in one place is the only way they stay said the same. The mode is
/// still returned, for a caller that wants to refresh something.
class ForwardMeetingDialog extends StatefulWidget {
  const ForwardMeetingDialog({
    super.key,
    required this.meetingSubject,
    required this.send,
    this.meetingWhen,
  });

  /// What is being forwarded, shown at the top so the recipient list is never
  /// typed against the wrong meeting.
  final String meetingSubject;

  /// The meeting's time, already formatted for display. Omitted when unknown.
  final String? meetingWhen;

  final Future<Either<Failure, MeetingForwardMode>> Function({
    required List<String> toAddresses,
    String? comment,
  }) send;

  static Future<MeetingForwardMode?> show(
    BuildContext context, {
    required String meetingSubject,
    String? meetingWhen,
    required Future<Either<Failure, MeetingForwardMode>> Function({
      required List<String> toAddresses,
      String? comment,
    }) send,
  }) {
    return showDialog<MeetingForwardMode>(
      context: context,
      builder: (_) => ForwardMeetingDialog(
        meetingSubject: meetingSubject,
        meetingWhen: meetingWhen,
        send: send,
      ),
    );
  }

  @override
  State<ForwardMeetingDialog> createState() => _ForwardMeetingDialogState();
}

enum _Stage { editing, sending, sent, failed }

class _ForwardMeetingDialogState extends State<ForwardMeetingDialog> {
  final _noteController = TextEditingController();
  List<String> _recipients = const [];
  _Stage _stage = _Stage.editing;
  MeetingForwardMode? _mode;
  String? _errorMessage;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_recipients.isEmpty || _stage == _Stage.sending) return;
    setState(() {
      _stage = _Stage.sending;
      _errorMessage = null;
    });

    final note = _noteController.text.trim();
    final result = await widget.send(
      toAddresses: _recipients,
      comment: note.isEmpty ? null : note,
    );

    if (!mounted) return;
    result.fold(
      (failure) => setState(() {
        _stage = _Stage.failed;
        _errorMessage = failure.message;
      }),
      (mode) => setState(() {
        _stage = _Stage.sent;
        _mode = mode;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final account = sl<AccountManager>().activeAccount;

    return AlertDialog(
      backgroundColor: c.surfacePanel,
      title: Text(
        'Forward meeting',
        style: TextStyle(color: c.textPrimary, fontSize: 15),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.meetingSubject,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (widget.meetingWhen != null) ...[
              const SizedBox(height: 2),
              Text(
                widget.meetingWhen!,
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            if (_stage == _Stage.sent)
              _outcome(c)
            else ...[
              RecipientInputField(
                label: 'To',
                recipients: _recipients,
                onChanged: (r) => setState(() => _recipients = r),
                accountId: account?.id,
                accountDomain: account?.emailAddress.split('@').lastOrNull,
                hintText: 'Who should this meeting go to?',
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _noteController,
                enabled: _stage != _Stage.sending,
                minLines: 2,
                maxLines: 4,
                style: TextStyle(color: c.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Add a note (optional)',
                  hintStyle: TextStyle(color: c.textDimmed, fontSize: 12),
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_stage == _Stage.failed && _errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red.shade400, fontSize: 12),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: _stage == _Stage.sent
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(_mode),
                child: Text('Done',
                    style: TextStyle(color: c.textMuted, fontSize: 13)),
              ),
            ]
          : [
              TextButton(
                onPressed: _stage == _Stage.sending
                    ? null
                    : () => Navigator.of(context).pop(),
                child: Text('Cancel',
                    style: TextStyle(color: c.textMuted, fontSize: 13)),
              ),
              FilledButton.icon(
                onPressed:
                    _recipients.isEmpty || _stage == _Stage.sending ? null : _send,
                style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                icon: _stage == _Stage.sending
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: Colors.white),
                      )
                    : const Icon(Icons.forward_to_inbox_rounded, size: 14),
                label: Text(
                  _stage == _Stage.sending ? 'Forwarding…' : 'Forward',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
    );
  }

  /// What actually happened, said plainly.
  ///
  /// The distinction is worth the words: after an on-behalf-of forward the
  /// recipient is on the organiser's guest list and will get later changes,
  /// and after the emailed fallback they are not and will not — which is only
  /// fixable by the organiser, so the reader has to be told.
  Widget _outcome(AppColors c) {
    final onBehalf = _mode == MeetingForwardMode.onBehalfOfOrganizer;
    final who = _recipients.join(', ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          onBehalf ? Icons.check_circle_outline_rounded : Icons.info_outline_rounded,
          size: 16,
          color: onBehalf ? Colors.green.shade600 : Colors.orange.shade700,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            onBehalf
                ? 'Forwarded to $who. They have been added to the meeting, so '
                    'their reply goes to the organiser and they will get any '
                    'later changes.'
                : 'Sent to $who from you. The organiser could not be asked to '
                    'add them, so they are not on the guest list — they can '
                    'still accept the invitation, which replies to the '
                    'organiser directly.',
            style: TextStyle(color: c.textTertiary, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}
