import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart';

import '../../../core/error/failures.dart';
import '../../../core/platform/touch_metrics.dart';
import '../../../core/theme/app_colors.dart';
import '../../blocs/ai/agent_chat_cubit.dart';
import '../../blocs/ai/ai_folder_chat_state.dart';

/// The chat side pane every [AgentChatCubit] is shown in: the main window's
/// folder assistant ([AiDayPanel]) and the compose window's writing
/// assistant. The host supplies the turn ([onSend]), the strings, and how a
/// tool card is drawn; the pane reconciles the cubit's transcript into the
/// chat kit.
class AgentChatPanel extends StatefulWidget {
  const AgentChatPanel({
    super.key,
    required this.cubit,
    required this.onSend,
    required this.onClose,
    required this.toolCardBuilder,
    this.title = 'AI Assistant',
    this.welcomeTitle = '',
    this.hintText = 'Message…',
    this.failureText = _failureMessage,
    this.useBackNavigation = false,
  });

  final AgentChatCubit cubit;

  /// Starts a turn for the (trimmed, non-empty) instruction.
  final ValueChanged<String> onSend;

  final VoidCallback onClose;

  /// Draws an inline tool card; one per [AiToolItem] in the transcript.
  final Widget Function(AiToolItem item) toolCardBuilder;

  final String title;
  final String welcomeTitle;
  final String hintText;

  /// The text a failed turn shows. A host whose failures can carry raw
  /// provider bodies maps them to a fixed message here.
  final String Function(Failure failure) failureText;

  /// True when the panel was pushed as a route rather than docked as a side
  /// pane — the mobile shell. It then dismisses through a leading back arrow,
  /// like the reading pane, instead of a trailing close button.
  final bool useBackNavigation;

  static String _failureMessage(Failure failure) => failure.message;

  /// The header's height, which a host lines its own title bar up with.
  static double get headerHeight => touchRowHeight(48);

  /// The input strip's height on the desktop: a 32px box over an 8px foot. A
  /// host lines its own footer up with it — the compose window's footer
  /// divider meets the top of the box. Touch screens keep the kit's larger
  /// tap targets and this does not apply.
  static const double compactInputBarHeight = 40;

  /// The desktop input box's resting height (its 1px border aside): one line.
  static const double _compactFieldHeight = 30;

  /// How far the desktop box may grow as the text wraps, as a share of the
  /// pane's height. Past it the text scrolls inside the box.
  static const double _maxInputShare = 0.2;

  @override
  State<AgentChatPanel> createState() => _AgentChatPanelState();
}

class _AgentChatPanelState extends State<AgentChatPanel> {
  final _chatController = ChatMessagesController();
  final _inputController = TextEditingController();

  static const _user = ChatUser(id: 'user', name: 'You');
  static const _ai = ChatUser(id: 'ai', name: 'AI Assistant');

  /// Mirrors the [AiChatItem]s already pushed into the controller, keyed by id,
  /// so each new state reconciles items instead of rebuilding the transcript.
  final Map<String, ChatMessage> _byId = {};

  /// The last-rendered [AiToolItem] per id, so a status/output change re-renders
  /// the tool card (the kit's [ChatMessage] equality ignores `customBuilder`).
  final Map<String, AiToolItem> _toolById = {};

  /// Whether a turn is in flight; drives the LoadingConfig + Stop button.
  bool _isLoading = false;

  /// The text the input's height was last worked out for. The box's height
  /// depends only on the text, so a caret move or selection doesn't rebuild.
  String _sizedText = '';

  @override
  void initState() {
    super.initState();
    _inputController.addListener(_onInputChanged);
    // The cubit outlives the pane: closing and reopening it builds a fresh
    // controller, and the listener only hears states emitted from now on, so
    // the conversation so far is replayed once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync(context, widget.cubit.state);
    });
  }

  @override
  void dispose() {
    _chatController.dispose();
    _inputController.removeListener(_onInputChanged);
    _inputController.dispose();
    super.dispose();
  }

  /// Hands the instruction to the host. The transcript (including the user
  /// bubble) is rendered from the emitted state in [_sync] — we do not touch
  /// the controller here.
  void _onSend(ChatMessage userMessage) {
    final instruction = userMessage.text.trim();
    if (instruction.isEmpty || _isLoading) return;
    widget.onSend(instruction);
  }

  /// Cancels an in-flight turn; the cubit settles the partial bubble and emits
  /// a non-streaming state, which [_sync] reflects.
  void _onCancelGenerating() {
    widget.cubit.cancel();
  }

  /// Clears the conversation and starts a fresh chat.
  void _newChat() {
    widget.cubit.reset();
  }

  /// Reconciles the chat controller with the emitted [AiFolderChatState]: the
  /// kit owns rendering, so this listener is the only place that mutates the
  /// transcript.
  void _sync(BuildContext context, AiFolderChatState state) {
    // New Chat / empty transcript.
    if (state.messages.isEmpty) {
      if (_byId.isNotEmpty) {
        _chatController.clearMessages();
        _byId.clear();
        _toolById.clear();
      }
      // A failure with no turn to hang it on (nothing sent yet).
      final failure = state.failure;
      if (failure != null) {
        final errId = 'err_none_${identityHashCode(failure)}';
        if (!_byId.containsKey(errId)) {
          final cm = ChatMessage(
            text: '⚠️ ${widget.failureText(failure)}',
            user: _ai,
            createdAt: DateTime.now(),
            customProperties: {'id': errId},
          );
          _byId[errId] = cm;
          _chatController.addMessage(cm);
        }
      }
      _setLoading(state.isStreaming);
      return;
    }

    // Add new items and update changed ones (a streaming assistant bubble whose
    // text grew, or a tool card transitioning running → complete/error).
    for (final item in state.messages) {
      switch (item) {
        case AiToolItem():
          _syncToolItem(item);
        case AiTextMessage():
          _syncTextMessage(item);
      }
    }

    // Stop the streaming animation on assistant bubbles once the turn settles.
    if (!state.isStreaming) {
      for (final m in state.messages) {
        if (m is AiTextMessage && !m.isUser) {
          _chatController.stopStreamingMessage(m.id);
        }
      }
    }

    // Surface a hard failure: append it to the trailing assistant bubble if one
    // exists for this turn, else add a dedicated error bubble. An assistant
    // bubble before the last user bubble belongs to an earlier turn.
    if (state.failure != null) {
      final errText = '⚠️ ${widget.failureText(state.failure!)}';
      AiTextMessage? lastAssistant;
      for (final m in state.messages) {
        if (m is AiTextMessage) lastAssistant = m.isUser ? null : m;
      }
      if (lastAssistant != null && _byId[lastAssistant.id] != null) {
        final existing = _byId[lastAssistant.id]!;
        final merged = existing.text.isEmpty
            ? errText
            : '${existing.text}\n\n$errText';
        final updated = existing.copyWith(text: merged);
        _byId[lastAssistant.id] = updated;
        _chatController.updateMessage(updated);
      } else {
        // Turn-stable id: keyed off the last message in this turn so repeated
        // re-emissions of the same failure dedupe via the containsKey guard,
        // even when controller-only inserts have changed _byId.length.
        final errId = 'err_${state.messages.last.id}';
        if (!_byId.containsKey(errId)) {
          final cm = ChatMessage(
            text: errText,
            user: _ai,
            createdAt: DateTime.now(),
            customProperties: {'id': errId},
          );
          _byId[errId] = cm;
          _chatController.addMessage(cm);
        }
      }
    }

    _setLoading(state.isStreaming);
  }

  /// Reconciles a single text bubble into the controller.
  void _syncTextMessage(AiTextMessage m) {
    final existing = _byId[m.id];
    if (existing == null) {
      // Don't render an empty in-flight assistant bubble: the cubit may drop
      // it (failure/cancel before any output). Add it on its first delta.
      if (!m.isUser && m.text.isEmpty) return;
      final cm = ChatMessage(
        text: m.text,
        user: m.isUser ? _user : _ai,
        createdAt: DateTime.now(),
        isMarkdown: !m.isUser,
        customProperties: {'id': m.id},
      );
      _byId[m.id] = cm;
      if (m.isUser) {
        _chatController.addMessage(cm);
      } else {
        _chatController.addStreamingMessage(cm);
      }
    } else if (existing.text != m.text) {
      final updated = existing.copyWith(text: m.text);
      _byId[m.id] = updated;
      _chatController.updateMessage(updated);
    }
  }

  /// Reconciles a single inline tool card into the controller. The card is a
  /// full-width custom-builder message (no bubble chrome); a status/output
  /// change rebuilds its card in place.
  void _syncToolItem(AiToolItem item) {
    final prev = _toolById[item.id];
    if (prev == item) return;
    _toolById[item.id] = item;

    final cm = (_byId[item.id] ??
            ChatMessage(
              text: '',
              user: _ai,
              createdAt: DateTime.now(),
              customProperties: {'id': item.id},
            ))
        .copyWith(
          customBuilder: (context, _) => widget.toolCardBuilder(item),
        );
    _byId[item.id] = cm;

    if (prev == null) {
      _chatController.addMessage(cm);
    } else {
      _chatController.updateMessage(cm);
    }
  }

  void _onInputChanged() {
    if (_inputController.text == _sizedText) return;
    setState(() => _sizedText = _inputController.text);
  }

  /// The desktop input field's height for [_sizedText] in a pane [paneSize]:
  /// the one-line [AgentChatPanel._compactFieldHeight], plus each wrapped or
  /// typed line after the first, capped at [AgentChatPanel._maxInputShare] of
  /// the pane.
  ///
  /// The kit sizes the field and the send button from one fixed `inputHeight`
  /// (leaving it null floors the row at 48), so the height is worked out here
  /// rather than left to the field. The text width mirrors the kit's row:
  /// [_inputMaterialPadding], the box's 1px border, the send button,
  /// [_inputContentPadding], and the caret margin [RenderEditable] reserves.
  double _compactInputHeight(Size paneSize, TextStyle style) {
    const minHeight = AgentChatPanel._compactFieldHeight;
    final text = _sizedText.isEmpty ? ' ' : _sizedText;
    final textWidth = paneSize.width -
        _inputMaterialPadding.horizontal -
        2 -
        _CompactInputButton.size -
        _inputContentPadding.horizontal -
        3;
    if (textWidth <= 0 || !paneSize.height.isFinite) return minHeight;

    final scaler = MediaQuery.textScalerOf(context);
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout(maxWidth: textWidth);
    final oneLine = TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout();
    final extra = painter.height - oneLine.height;
    painter.dispose();
    oneLine.dispose();

    final maxHeight = (paneSize.height * AgentChatPanel._maxInputShare)
        .clamp(minHeight, double.infinity);
    return (minHeight + extra).clamp(minHeight, maxHeight);
  }

  static const _inputMaterialPadding = EdgeInsets.fromLTRB(8, 0, 8, 8);
  static const _inputContentPadding =
      EdgeInsets.symmetric(horizontal: 10, vertical: 8);

  void _setLoading(bool loading) {
    if (_isLoading != loading) setState(() => _isLoading = loading);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfacePanel,
      child: Column(
        children: [
          _Header(
            title: widget.title,
            onClose: widget.onClose,
            onNewChat: _newChat,
            useBackNavigation: widget.useBackNavigation,
          ),
          Divider(height: 1, color: c.separatorStrong),
          Expanded(
            child: BlocListener<AgentChatCubit, AiFolderChatState>(
              bloc: widget.cubit,
              listener: _sync,
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _buildChat(c, constraints.biggest),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChat(AppColors c, Size paneSize) {
    final base = Theme.of(context);
    final onAccent =
        AppColors.accent.computeLuminance() > 0.5 ? Colors.black : Colors.white;

    // The kit reads colorScheme.surface / surfaceContainer* for its own
    // backgrounds; align them with the panel palette so the chat surface
    // matches the surrounding dark UI.
    final inputStyle = TextStyle(color: c.textPrimary, fontSize: 13);
    final theme = base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.accent,
        surface: c.surfacePanel,
        onSurface: c.textPrimary,
        surfaceContainerLowest: c.surfacePanel,
        surfaceContainerLow: c.surfacePanel,
        surfaceContainer: c.surfacePanel,
        surfaceContainerHigh: c.surfaceBase,
        surfaceContainerHighest: c.surfaceBase,
      ),
    );

    return Theme(
      data: theme,
      child: AiChatWidget(
        currentUser: _user,
        aiUser: _ai,
        controller: _chatController,
        onSendMessage: _onSend,

        // Streaming animation — both flags required for word-by-word.
        enableMarkdownStreaming: true,
        streamingWordByWord: true,
        streamingDuration: const Duration(milliseconds: 25),

        // Stop button: appears in the input while generating.
        loadingConfig: LoadingConfig(isLoading: _isLoading),
        onCancelGenerating: _onCancelGenerating,

        welcomeMessageConfig: WelcomeMessageConfig(
          centerVertically: true,
          title: widget.welcomeTitle,
          titleStyle: TextStyle(
            color: c.textMuted,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          containerDecoration: const BoxDecoration(),
        ),

        messageOptions: MessageOptions(
          showTime: false,
          showCopyButton: true,
          aiTextColor: c.textPrimary,
          userTextColor: onAccent,
          textStyle: TextStyle(color: c.textPrimary, fontSize: 13, height: 1.5),
          bubbleStyle: BubbleStyle(
            aiBubbleColor: c.surfaceBase,
            userBubbleColor: AppColors.accent,
            aiNameColor: c.textMuted,
            userNameColor: onAccent,
            copyIconColor: c.textMuted,
            enableShadow: false,
            userBubbleTopLeftRadius: 10,
            userBubbleTopRightRadius: 10,
            aiBubbleTopLeftRadius: 10,
            aiBubbleTopRightRadius: 10,
            bottomLeftRadius: 10,
            bottomRightRadius: 10,
          ),
        ),

        inputOptions: InputOptions(
          textController: _inputController,
          textStyle: inputStyle,
          // Multi-line text grows the box (see [_compactInputHeight]); past
          // its cap the field scrolls rather than clipping lines.
          maxLines: isTouchPlatform ? 5 : null,
          sendButtonColor: AppColors.accent,
          decoration: InputDecoration(
            hintText: widget.hintText,
            hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
            border: InputBorder.none,
            contentPadding: _inputContentPadding,
            isDense: true,
          ),
          containerDecoration: BoxDecoration(
            color: c.surfacePanel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.border),
          ),
          // The kit floors the send button's row at 48 unless the field has
          // an explicit height. On the desktop that made the box 50 tall;
          // [compactInputBarHeight] is the one-line box: 30 + the 1px border
          // each side, and no padding above the box. Longer text grows it.
          inputHeight: isTouchPlatform
              ? null
              : _compactInputHeight(
                  paneSize, base.textTheme.bodyLarge!.merge(inputStyle)),
          materialPadding: isTouchPlatform ? null : _inputMaterialPadding,
          sendButtonBuilder: isTouchPlatform
              ? null
              : (onSend) => _CompactInputButton(
                    icon: Icons.send_rounded,
                    tooltip: 'Send',
                    onPressed: onSend,
                  ),
          cancelButtonBuilder: isTouchPlatform
              ? null
              : (onCancel) => _CompactInputButton(
                    icon: Icons.stop_rounded,
                    tooltip: 'Stop',
                    onPressed: onCancel,
                  ),
        ),
      ),
    );
  }
}

class _CompactInputButton extends StatelessWidget {
  const _CompactInputButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  /// The button's width and height.
  static const double size = 28;

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, size: 16, color: AppColors.accent),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: size, minHeight: size),
        onPressed: onPressed,
      );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.onClose,
    required this.onNewChat,
    this.useBackNavigation = false,
  });

  final String title;
  final VoidCallback onClose;
  final VoidCallback onNewChat;
  final bool useBackNavigation;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: AgentChatPanel.headerHeight,
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
            Icon(Icons.auto_awesome_rounded,
                size: touchIcon(16), color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.add_comment_outlined,
                  size: touchIcon(16), color: c.textMuted),
              tooltip: 'New Chat',
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: touchTarget(28),
                minHeight: touchTarget(28),
              ),
              onPressed: onNewChat,
            ),
            if (!useBackNavigation)
              IconButton(
                icon: Icon(Icons.close, size: touchIcon(16), color: c.textMuted),
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
