import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/platform/touch_metrics.dart';
import '../../../core/theme/app_colors.dart';
import '../../blocs/ai/ai_folder_chat_state.dart';
import '../../blocs/commitments/commitments_agent_cubit.dart';
import '../ai/tool_call_card.dart';

/// Natural-language control over the ledger, as a chat: type what should
/// change, watch the agent's tool calls land as cards, read what changed.
///
/// Two layouts over one [CommitmentsAgentCubit]:
///
/// * **Compact** (the side pane): an input bar pinned to the bottom; the
///   transcript folds out above it once there is one, capped in height so
///   the ledger keeps the pane.
/// * **Wide** (the detached window): a full-height column with the
///   transcript filling it and the input at the foot.
///
/// Examples are offered while the transcript is empty, so the kind of
/// instruction the agent understands is visible without a manual.
class CommitmentsAssistant extends StatefulWidget {
  const CommitmentsAssistant({super.key, required this.compact});

  final bool compact;

  static const List<String> examples = [
    'Move everything non-urgent to Friday',
    'Give me 2 hours tomorrow for the AWS work',
    'What is overloaded this week?',
    'Mark the migration numbers done',
  ];

  @override
  State<CommitmentsAssistant> createState() => _CommitmentsAssistantState();
}

class _CommitmentsAssistantState extends State<CommitmentsAssistant> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    final cubit = context.read<CommitmentsAgentCubit>();
    final instruction = (text ?? _controller.text).trim();
    if (instruction.isEmpty || cubit.state.isStreaming) return;
    cubit.send(instruction);
    _controller.clear();
    _focus.requestFocus();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocConsumer<CommitmentsAgentCubit, AiFolderChatState>(
      listener: (_, _) => _scrollToEnd(),
      builder: (context, state) {
        final transcript = _Transcript(
          state: state,
          controller: _scroll,
          compact: widget.compact,
          onExample: _send,
        );
        final input = _InputBar(
          controller: _controller,
          focusNode: _focus,
          streaming: state.isStreaming,
          hasTranscript: state.messages.isNotEmpty,
          onSend: _send,
          onStop: () => context.read<CommitmentsAgentCubit>().cancel(),
          onClear: () => context.read<CommitmentsAgentCubit>().reset(),
        );

        if (widget.compact) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Divider(height: 1, color: c.separatorStrong),
              if (state.messages.isNotEmpty || state.failure != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: transcript,
                ),
              input,
            ],
          );
        }
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
                    const Icon(Icons.auto_awesome_rounded,
                        size: 16, color: AppColors.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'ASSISTANT',
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: c.separatorStrong),
              Expanded(child: transcript),
              Divider(height: 1, color: c.separatorStrong),
              input,
            ],
          ),
        );
      },
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.state,
    required this.controller,
    required this.compact,
    required this.onExample,
  });

  final AiFolderChatState state;
  final ScrollController controller;
  final bool compact;
  final ValueChanged<String> onExample;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (state.messages.isEmpty && state.failure == null) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tell me what to change and I will move the blocks, book the '
              'time and close what is done.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in CommitmentsAssistant.examples)
                  ActionChip(
                    label: Text(e, style: const TextStyle(fontSize: 12)),
                    onPressed: () => onExample(e),
                    backgroundColor: c.surfaceBase,
                    side: BorderSide(color: c.separatorStrong),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      );
    }
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      shrinkWrap: compact,
      children: [
        for (final item in state.messages)
          switch (item) {
            AiTextMessage() => _Bubble(message: item),
            AiToolItem() => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ToolCallCard(item: item),
              ),
          },
        if (state.failure != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: c.errorBannerBg,
              border: Border.all(color: c.errorBannerBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              state.failure!.message,
              style: TextStyle(color: c.errorBannerText, fontSize: 12),
            ),
          ),
        if (state.isStreaming)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: c.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Working…',
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final AiTextMessage message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final user = message.isUser;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: user ? AppColors.accent.withAlpha(36) : c.surfaceBase,
          border: Border.all(
            color: user ? AppColors.accent.withAlpha(90) : c.separatorStrong,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          message.text,
          style: TextStyle(color: c.textSecondary, fontSize: 12, height: 1.35),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.streaming,
    required this.hasTranscript,
    required this.onSend,
    required this.onStop,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool streaming;
  final bool hasTranscript;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: !streaming,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              style: TextStyle(color: c.textSecondary, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Tell me what to change…',
                hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                prefixIcon: Icon(Icons.auto_awesome_rounded,
                    size: 16, color: c.textMuted),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                filled: true,
                fillColor: c.surfaceBase,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.separatorStrong),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.separator),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.accent),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (streaming)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              color: AppColors.notification,
              tooltip: 'Stop',
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: touchTarget(28),
                minHeight: touchTarget(28),
              ),
              onPressed: onStop,
            )
          else
            IconButton(
              icon: const Icon(Icons.send_rounded, size: 18),
              color: AppColors.accent,
              tooltip: 'Send',
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: touchTarget(28),
                minHeight: touchTarget(28),
              ),
              onPressed: onSend,
            ),
          if (hasTranscript && !streaming)
            IconButton(
              icon: Icon(Icons.delete_sweep_outlined, size: 18, color: c.textMuted),
              tooltip: 'Clear conversation',
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: touchTarget(28),
                minHeight: touchTarget(28),
              ),
              onPressed: onClear,
            ),
        ],
      ),
    );
  }
}
