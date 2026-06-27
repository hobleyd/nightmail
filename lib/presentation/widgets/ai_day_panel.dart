import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/ai/ai_compose_state.dart';
import '../blocs/ai/ai_folder_cubit.dart';

sealed class _ChatMsg {}

final class _UserMsg extends _ChatMsg {
  _UserMsg(this.text);
  final String text;
}

final class _AiMsg extends _ChatMsg {
  _AiMsg()
      : text = '',
        streaming = true,
        error = null;
  String text;
  bool streaming;
  String? error;
}

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
  final List<_ChatMsg> _messages = [];

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
    setState(() {
      _messages.add(_UserMsg(instruction));
      _messages.add(_AiMsg());
    });
    _controller.clear();
    final emailContext = widget.contextProvider?.call();
    context.read<AiFolderCubit>().generate(instruction, context: emailContext);
    _scrollToBottom();
  }

  void _stop() {
    context.read<AiFolderCubit>().cancel();
    setState(() {
      if (_messages.isNotEmpty && _messages.last is _AiMsg) {
        (_messages.last as _AiMsg).streaming = false;
      }
    });
  }

  void _clear() {
    context.read<AiFolderCubit>().cancel();
    setState(() => _messages.clear());
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocConsumer<AiFolderCubit, AiComposeState>(
      listener: (context, state) {
        if (state is AiComposeStreaming) {
          setState(() {
            if (_messages.isNotEmpty && _messages.last is _AiMsg) {
              (_messages.last as _AiMsg).text = state.text;
            }
          });
          _scrollToBottom();
        } else if (state is AiComposeDone) {
          setState(() {
            if (_messages.isNotEmpty && _messages.last is _AiMsg) {
              final msg = _messages.last as _AiMsg;
              msg.text = state.text;
              msg.streaming = false;
            }
          });
          _scrollToBottom();
        } else if (state is AiComposeError) {
          setState(() {
            if (_messages.isNotEmpty && _messages.last is _AiMsg) {
              final msg = _messages.last as _AiMsg;
              msg.error = state.failure.message;
              msg.streaming = false;
            }
          });
        }
      },
      builder: (context, state) {
        final isGenerating = state is AiComposeStreaming;
        return ColoredBox(
          color: c.surfacePanel,
          child: Column(
            children: [
              _Header(onClose: widget.onClose),
              Divider(height: 1, color: c.separatorStrong),
              Expanded(child: _buildMessages(c)),
              Divider(height: 1, color: c.separatorStrong),
              _buildInput(context, c, isGenerating),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessages(AppColors c) {
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          'Ask anything about your emails.',
          style: TextStyle(color: c.textMuted, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      );
    }
    return Scrollbar(
      controller: _scrollController,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        itemCount: _messages.length,
        itemBuilder: (context, i) {
          final msg = _messages[i];
          return switch (msg) {
            _UserMsg() => _UserBubble(text: msg.text, c: c),
            _AiMsg() => _AiBubble(msg: msg, c: c),
          };
        },
      ),
    );
  }

  Widget _buildInput(BuildContext context, AppColors c, bool isGenerating) {
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
              hintText: 'Ask about your emails…',
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
              if (_messages.isNotEmpty && !isGenerating)
                TextButton(
                  onPressed: _clear,
                  style: TextButton.styleFrom(
                    foregroundColor: c.textMuted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Clear', style: TextStyle(fontSize: 13)),
                ),
              const Spacer(),
              if (isGenerating)
                TextButton(
                  onPressed: _stop,
                  style: TextButton.styleFrom(
                    foregroundColor: c.textMuted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Stop', style: TextStyle(fontSize: 13)),
                )
              else
                FilledButton.icon(
                  onPressed: _generate,
                  icon: const Icon(Icons.send_rounded, size: 14),
                  label:
                      const Text('Send', style: TextStyle(fontSize: 13)),
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

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, required this.c});

  final String text;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 40),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            text,
            style: const TextStyle(
                color: Colors.white, fontSize: 13, height: 1.4),
          ),
        ),
      ),
    );
  }
}

class _AiBubble extends StatelessWidget {
  const _AiBubble({required this.msg, required this.c});

  final _AiMsg msg;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, right: 40),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.auto_awesome_rounded,
                size: 14, color: AppColors.accent),
          ),
          const SizedBox(width: 8),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (msg.error != null) {
      return Text(
        msg.error!,
        style: TextStyle(
            color: Colors.red.shade400, fontSize: 13, height: 1.5),
      );
    }
    if (msg.text.isEmpty && msg.streaming) {
      return const _StreamingCursorInline();
    }
    return SelectableText.rich(
      TextSpan(
        children: [
          TextSpan(
            text: msg.text,
            style: TextStyle(color: c.textPrimary, fontSize: 13, height: 1.5),
          ),
          if (msg.streaming)
            const WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _StreamingCursorInline(),
            ),
        ],
      ),
    );
  }
}

class _StreamingCursorInline extends StatefulWidget {
  const _StreamingCursorInline();

  @override
  State<_StreamingCursorInline> createState() => _StreamingCursorInlineState();
}

class _StreamingCursorInlineState extends State<_StreamingCursorInline>
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
