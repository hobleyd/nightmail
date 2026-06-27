import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/ai/ai_compose_state.dart';
import '../blocs/ai/ai_folder_cubit.dart';

class AiDayPanel extends StatefulWidget {
  const AiDayPanel({
    super.key,
    required this.onClose,
    this.contextProvider,
  });

  final VoidCallback onClose;

  /// Called just before generation to collect the context string to pass to the
  /// AI (e.g. a formatted excerpt of the current folder's emails). Returns null
  /// when no context is available.
  final String? Function()? contextProvider;

  @override
  State<AiDayPanel> createState() => _AiDayPanelState();
}

class _AiDayPanelState extends State<AiDayPanel> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _inputFocus.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        if (context.read<AiFolderCubit>().state is! AiComposeStreaming) {
          _generate();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _generate() {
    final instruction = _controller.text.trim();
    if (instruction.isEmpty) return;
    final emailContext = widget.contextProvider?.call();
    context.read<AiFolderCubit>().generate(instruction, context: emailContext);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocConsumer<AiFolderCubit, AiComposeState>(
      listener: (context, state) {
        if (state is AiComposeStreaming || state is AiComposeDone) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.jumpTo(
                _scrollController.position.maxScrollExtent,
              );
            }
          });
        }
      },
      builder: (context, state) {
        return ColoredBox(
          color: c.surfacePanel,
          child: Column(
            children: [
              _Header(onClose: widget.onClose),
              Divider(height: 1, color: c.separatorStrong),
              Expanded(child: _buildOutput(c, state)),
              Divider(height: 1, color: c.separatorStrong),
              _buildInput(context, c, state),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOutput(AppColors c, AiComposeState state) {
    return switch (state) {
      AiComposeIdle() => Center(
          child: Text(
            'Enter an instruction to draft with AI.',
            style: TextStyle(color: c.textMuted, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      AiComposeStreaming(:final text) => _TextOutput(
          scrollController: _scrollController,
          text: text,
          trailing: _StreamingCursor(c: c),
        ),
      AiComposeDone(:final text) => _TextOutput(
          scrollController: _scrollController,
          text: text,
        ),
      AiComposeError(:final failure) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            failure.message,
            style: TextStyle(color: Colors.red.shade400, fontSize: 13),
          ),
        ),
    };
  }

  Widget _buildInput(
      BuildContext context, AppColors c, AiComposeState state) {
    final isGenerating = state is AiComposeStreaming;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            focusNode: _inputFocus,
            enabled: !isGenerating,
            minLines: 2,
            maxLines: 4,
            style: TextStyle(color: c.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Describe what to write…',
              hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: AppColors.accent, width: 1.5),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (state is AiComposeDone || state is AiComposeError)
                TextButton(
                  onPressed: () =>
                      context.read<AiFolderCubit>().cancel(),
                  style: TextButton.styleFrom(
                    foregroundColor: c.textMuted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child:
                      const Text('Clear', style: TextStyle(fontSize: 13)),
                ),
              const Spacer(),
              if (isGenerating)
                TextButton(
                  onPressed: () =>
                      context.read<AiFolderCubit>().cancel(),
                  style: TextButton.styleFrom(
                    foregroundColor: c.textMuted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child:
                      const Text('Stop', style: TextStyle(fontSize: 13)),
                )
              else
                FilledButton.icon(
                  onPressed: _generate,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 14),
                  label: const Text('Generate',
                      style: TextStyle(fontSize: 13)),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 16, color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'AI Assistant',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 16, color: c.textMuted),
              tooltip: 'Close',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _TextOutput extends StatelessWidget {
  const _TextOutput({
    required this.scrollController,
    required this.text,
    this.trailing,
  });

  final ScrollController scrollController;
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scrollbar(
      controller: scrollController,
      child: SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.all(16),
        child: SelectableText.rich(
          TextSpan(
            children: [
              TextSpan(
                text: text,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              if (trailing != null)
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: trailing!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor({required this.c});
  final AppColors c;

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _blink,
      child: Container(
        width: 2,
        height: 14,
        color: AppColors.accent,
      ),
    );
  }
}
