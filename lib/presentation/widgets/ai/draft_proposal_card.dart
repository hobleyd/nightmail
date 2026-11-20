import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';

/// What applying a proposal came to: the undo, or why it was refused.
class DraftApplyOutcome {
  const DraftApplyOutcome.applied(Future<void> Function() this.undo)
      : refusal = null;
  const DraftApplyOutcome.refused(String this.refusal) : undo = null;

  /// Puts back what was there before.
  final Future<void> Function()? undo;

  /// Safe to show; drawn on the card.
  final String? refusal;
}

/// Puts a proposal into the message.
typedef ApplyDraftProposal = Future<DraftApplyOutcome> Function(String text);

enum DraftProposalStatus { applying, applied, undone, refused }

/// One `propose_draft` call's life in the message: put in as soon as it
/// arrives, undone and applied again from its card.
///
/// Owned by the compose form, one per tool call, rather than by the card: the
/// chat kit rebuilds cards freely and reopening the pane replays the whole
/// transcript, and neither may apply a proposal a second time.
class DraftProposal extends ChangeNotifier {
  DraftProposal(this.text, this._apply);

  final String text;
  final ApplyDraftProposal _apply;

  DraftProposalStatus status = DraftProposalStatus.applying;
  String? refusal;
  Future<void> Function()? _undo;
  bool _disposed = false;

  Future<void> apply() async {
    status = DraftProposalStatus.applying;
    refusal = null;
    notifyListeners();
    final outcome = await _apply(text);
    if (_disposed) return;
    _undo = outcome.undo;
    refusal = outcome.refusal;
    status = outcome.undo != null
        ? DraftProposalStatus.applied
        : DraftProposalStatus.refused;
    notifyListeners();
  }

  Future<void> undo() async {
    final undo = _undo;
    if (undo == null) return;
    _undo = null;
    status = DraftProposalStatus.applying;
    notifyListeners();
    await undo();
    if (_disposed) return;
    status = DraftProposalStatus.undone;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The compose assistant's proposal as it sits in the chat: the text that was
/// put into the message, Undo (Apply again once undone), and Copy. A refusal
/// says why and leaves Copy as the way in.
class DraftProposalCard extends StatefulWidget {
  const DraftProposalCard({super.key, required this.proposal});

  final DraftProposal proposal;

  @override
  State<DraftProposalCard> createState() => _DraftProposalCardState();
}

class _DraftProposalCardState extends State<DraftProposalCard> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.proposal.text));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.proposal,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final c = context.colors;
    final proposal = widget.proposal;
    final text = proposal.text;
    final status = proposal.status;
    final applied = status == DraftProposalStatus.applied;
    final title = switch (status) {
      DraftProposalStatus.applying => 'Putting it in your message…',
      DraftProposalStatus.applied => 'Put in your message',
      DraftProposalStatus.undone => 'Undone',
      DraftProposalStatus.refused => 'Not put in your message',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Container(
        decoration: BoxDecoration(
          color: c.surfaceBase,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: applied ? AppColors.accent : c.separatorStrong,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Row(
                children: [
                  Icon(Icons.edit_note_rounded,
                      size: 16, color: AppColors.accent),
                  const SizedBox(width: 6),
                  Text(
                    title,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                child: SelectableText(
                  text.isEmpty ? '(empty)' : text,
                  style: TextStyle(
                    color: text.isEmpty ? c.textMuted : c.textPrimary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ),
            ),
            if (proposal.refusal != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Text(
                  proposal.refusal!,
                  style: TextStyle(color: c.textSecondary, fontSize: 12),
                ),
              ),
            Divider(height: 1, color: c.separatorStrong),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  if (applied)
                    TextButton.icon(
                      onPressed: proposal.undo,
                      icon: const Icon(Icons.undo_rounded, size: 15),
                      label:
                          const Text('Undo', style: TextStyle(fontSize: 12.5)),
                      style: TextButton.styleFrom(
                          foregroundColor: c.textSecondary),
                    )
                  else
                    TextButton.icon(
                      onPressed: status == DraftProposalStatus.applying ||
                              text.isEmpty
                          ? null
                          : proposal.apply,
                      icon: const Icon(Icons.check_rounded, size: 15),
                      label: Text(
                          status == DraftProposalStatus.refused
                              ? 'Try again'
                              : 'Apply again',
                          style: const TextStyle(fontSize: 12.5)),
                      style: TextButton.styleFrom(
                          foregroundColor: AppColors.accent),
                    ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: text.isEmpty ? null : _copy,
                    icon: Icon(
                        _copied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 14),
                    label: Text(_copied ? 'Copied' : 'Copy',
                        style: const TextStyle(fontSize: 12.5)),
                    style:
                        TextButton.styleFrom(foregroundColor: c.textMuted),
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
