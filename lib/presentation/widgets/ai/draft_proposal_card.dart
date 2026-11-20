import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../blocs/ai/ai_folder_chat_state.dart';

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

/// The compose assistant's `propose_draft` call, drawn as the proposal itself:
/// the new text, Apply (which replaces what the user wrote above the quote,
/// leaving the signature and quote alone), Undo once applied, and Copy.
class DraftProposalCard extends StatefulWidget {
  const DraftProposalCard({
    super.key,
    required this.item,
    required this.onApply,
  });

  final AiToolItem item;
  final ApplyDraftProposal onApply;

  @override
  State<DraftProposalCard> createState() => _DraftProposalCardState();
}

class _DraftProposalCardState extends State<DraftProposalCard> {
  Future<void> Function()? _undo;
  String? _refusal;
  bool _busy = false;
  bool _copied = false;

  String get _text {
    final text = widget.item.args['text'];
    return text is String ? text.trim() : '';
  }

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _refusal = null;
    });
    final outcome = await widget.onApply(_text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _undo = outcome.undo;
      _refusal = outcome.refusal;
    });
  }

  Future<void> _revert() async {
    final undo = _undo;
    if (undo == null) return;
    setState(() => _busy = true);
    await undo();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _undo = null;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = _text;
    final applied = _undo != null;
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
                    applied ? 'Applied to your message' : 'Proposed message',
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
            if (_refusal != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Text(
                  _refusal!,
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
                      onPressed: _busy ? null : _revert,
                      icon: const Icon(Icons.undo_rounded, size: 15),
                      label: const Text('Undo', style: TextStyle(fontSize: 12.5)),
                      style: TextButton.styleFrom(
                          foregroundColor: c.textSecondary),
                    )
                  else
                    TextButton.icon(
                      onPressed: _busy || text.isEmpty ? null : _apply,
                      icon: const Icon(Icons.check_rounded, size: 15),
                      label: const Text('Apply',
                          style: TextStyle(fontSize: 12.5)),
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
