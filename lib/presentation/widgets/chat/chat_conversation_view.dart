import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../core/platform/touch_metrics.dart';
import '../../../core/text/emoji.dart';
import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/chat.dart';
import '../../blocs/chat/chat_conversation_cubit.dart';
import 'chat_message_body.dart';
import 'chat_person_style.dart';

/// A conversation's history and the box to write in, for the pane and the
/// window alike. In a channel, posts show their reply count and open a
/// thread; with [wideThreads] the thread sits beside the posts, otherwise it
/// covers them with a back arrow.
class ChatConversationView extends StatelessWidget {
  const ChatConversationView({super.key, this.wideThreads = false});

  final bool wideThreads;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<ChatConversationCubit, ChatConversationState>(
      builder: (context, state) {
        if (state.loading && state.messages.isEmpty) {
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.accent),
            ),
          );
        }
        if (state.unavailable) {
          return _Notice(
            icon: Icons.chat_bubble_outline,
            text: state.error ?? 'Chat is not available for this account.',
          );
        }
        final isChannel = state.conversation?.hasThreads ?? false;
        // A Slack DM threads too, but keeps its bubbles.
        final threads = context.read<ChatConversationCubit>().threads;
        final threadOpen = threads && state.threadPostId != null;

        final history = Column(
          children: [
            if (state.error != null) _ErrorBanner(text: state.error!),
            Expanded(
              child: state.messages.isEmpty && state.nextLink != null
                  // Nothing on the newest page to scroll from — the scroll
                  // trigger for older pages lives in the history list.
                  ? Center(
                      child: state.loadingOlder
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : TextButton(
                              onPressed: context
                                  .read<ChatConversationCubit>()
                                  .loadOlder,
                              child: const Text('Load older messages'),
                            ),
                    )
                  : state.messages.isEmpty
                  ? _Notice(
                      icon: Icons.forum_outlined,
                      text: state.conversation == null && state.person != null
                          ? 'No chat with ${state.person!.label} yet.\n'
                              'Your first message starts one.'
                          : 'No messages yet.',
                    )
                  : _History(
                      messages: state.messages,
                      isChannel: isChannel,
                      threads: threads,
                      canLoadOlder: state.nextLink != null,
                      loadingOlder: state.loadingOlder,
                      selectedPostId: state.threadPostId,
                    ),
            ),
            if (!threadOpen || wideThreads)
              _Composer(
                hint: isChannel
                    ? 'Start a new post'
                    : state.conversation == null && state.person != null
                        ? 'Message ${state.person!.label}'
                        : 'Type a message',
                sending: state.sending,
              ),
          ],
        );

        Widget colored(Widget child) => ChatPeopleColors(
              ownUserId: state.ownUserId,
              messages: [
                for (final m in state.messages) ...[m, ...m.replies],
                ...state.threadReplies,
              ],
              child: child,
            );
        if (!threadOpen) return colored(history);
        final thread = _ThreadPanel(
          post: state.threadPost,
          replies: state.threadReplies,
          loading: state.threadLoading,
          sending: state.sending,
          showBack: !wideThreads,
          backLabel: isChannel ? 'Back to posts' : 'Back to messages',
        );
        if (!wideThreads) return colored(thread);
        return colored(Row(
          children: [
            Expanded(flex: 3, child: history),
            VerticalDivider(width: 1, color: c.separatorStrong),
            Expanded(flex: 2, child: thread),
          ],
        ));
      },
    );
  }
}

class _History extends StatefulWidget {
  const _History({
    required this.messages,
    required this.isChannel,
    required this.threads,
    required this.canLoadOlder,
    required this.loadingOlder,
    this.selectedPostId,
  });

  final List<ChatMessage> messages;
  final bool isChannel;

  /// Each message can open a thread (a channel's posts, a Slack DM's
  /// messages).
  final bool threads;
  final bool canLoadOlder;
  final bool loadingOlder;
  final String? selectedPostId;

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_maybeLoadOlder);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The list is reversed — newest at the bottom, offset 0 — so the oldest
  /// edge is maxScrollExtent.
  void _maybeLoadOlder() {
    if (!widget.canLoadOlder || widget.loadingOlder) return;
    final p = _controller.position;
    if (p.pixels >= p.maxScrollExtent - 200) {
      context.read<ChatConversationCubit>().loadOlder();
    }
  }

  @override
  Widget build(BuildContext context) {
    final msgs = widget.messages;
    return SelectionArea(
      child: ListView.builder(
        controller: _controller,
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: msgs.length + (widget.loadingOlder ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == msgs.length) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final m = msgs[i];
          final older = i + 1 < msgs.length ? msgs[i + 1] : null;
          final newDay = older == null || !_sameDay(older.createdAt, m.createdAt);
          // Consecutive messages from one sender within five minutes share a
          // header, as every chat client does.
          final grouped = !widget.isChannel &&
              !newDay &&
              !older.isSystem &&
              !older.isDeleted &&
              older.senderName == m.senderName &&
              m.createdAt.difference(older.createdAt).inMinutes < 5;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (newDay) _DaySeparator(day: m.createdAt),
              _MessageTile(
                message: m,
                showHeader: !grouped,
                isPost: widget.isChannel,
                threads: widget.threads,
                selected: m.id == widget.selectedPostId,
              ),
            ],
          );
        },
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(day.year, day.month, day.day);
    final label = d == today
        ? 'Today'
        : d == today.subtract(const Duration(days: 1))
            ? 'Yesterday'
            : DateFormat(d.year == now.year ? 'EEEE d MMMM' : 'd MMMM y')
                .format(d);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Expanded(child: Divider(color: c.separator)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(label,
                style: TextStyle(fontSize: 11, color: c.textTertiary)),
          ),
          Expanded(child: Divider(color: c.separator)),
        ],
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.message,
    required this.showHeader,
    required this.isPost,
    required this.selected,
    this.threads = false,
    this.inThread = false,
  });

  /// Offers a Reply / "N replies" link that opens this message's thread — a
  /// post's always; a chat message's where the provider threads chats.
  final bool threads;

  /// Shown in the open thread: its pencil edits in the thread's composer.
  final bool inThread;

  final ChatMessage message;
  final bool showHeader;
  final bool isPost;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = message;
    if (m.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        child: Center(
          child: ChatMessageBody(
            html: m.bodyHtml,
            style: TextStyle(
                fontSize: 11.5,
                color: c.textTertiary,
                fontStyle: FontStyle.italic),
          ),
        ),
      );
    }
    // One muted line, without a sender — providers send a deleted message
    // without one, which read "Unknown" over "This message was deleted."
    // A channel post keeps its way into the replies it still has.
    if (m.isDeleted) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(50, 3, 12, 3),
        child: Row(
          children: [
            Icon(Icons.block, size: 12, color: c.textMuted),
            const SizedBox(width: 5),
            Text('Deleted message',
                style: TextStyle(
                    fontSize: 12,
                    color: c.textMuted,
                    fontStyle: FontStyle.italic)),
            if ((isPost || threads) && !inThread && m.totalReplies > 0) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: () =>
                    context.read<ChatConversationCubit>().openThread(m.id),
                child: Text(
                  m.totalReplies == 1 ? '1 reply' : '${m.totalReplies} replies',
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.accent,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
      );
    }
    final body = ChatMessageBody(
      html: m.bodyHtml,
      style: TextStyle(fontSize: 13, height: 1.35, color: c.textBody),
      loadImage: context.read<ChatConversationCubit>().image,
    );
    final person = ChatPersonStyle.of(context, m);

    final header = Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Flexible(
            child: Text(
              m.senderName.isEmpty ? 'Unknown' : m.senderName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: person.name,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            DateFormat.jm().format(m.createdAt),
            style: TextStyle(fontSize: 11, color: c.textMuted),
          ),
          if (m.editedAt != null) ...[
            const SizedBox(width: 6),
            Text('Edited',
                style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
        ],
      ),
    );

    final cubit = context.read<ChatConversationCubit>();
    final editable = cubit.canEdit(m);
    final reactable = cubit.canReact(m);

    // What sits in the sender's bubble (a chat) or card (a channel post).
    final bubbleContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.subject != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(m.subject!,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary)),
          ),
        body,
        for (final name in m.attachmentNames)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.attach_file, size: 13, color: c.textTertiary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.textSecondary)),
                ),
              ],
            ),
          ),
        if (m.reactions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final r in m.reactions)
                  _ReactionChip(
                    reaction: r,
                    own: cubit.isOwnReaction(r),
                    // Tapping someone else's adds the user's own; tapping
                    // the user's own takes it off.
                    onTap: !reactable
                        ? null
                        : cubit.isOwnReaction(r)
                            ? () => cubit.unreact(m, r.emoji)
                            : () => cubit.react(m, r.emoji),
                    child: r.imageUrl == null
                        ? Text(
                            r.count > 1 ? '${r.emoji} ${r.count}' : r.emoji,
                            style: const TextStyle(fontSize: 12),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ChatEmojiImage(
                                src: r.imageUrl!,
                                load: context
                                    .read<ChatConversationCubit>()
                                    .image,
                                alt: r.emoji,
                                size: 15,
                              ),
                              if (r.count > 1)
                                Text(' ${r.count}',
                                    style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                  ),
              ],
            ),
          ),
      ],
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader) header,
        if (isPost)
          bubbleContent
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: person.bubble,
              borderRadius: BorderRadius.circular(10),
            ),
            child: bubbleContent,
          ),
        if ((isPost || threads) && !inThread)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              onTap: () =>
                  context.read<ChatConversationCubit>().openThread(m.id),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.reply_rounded,
                        size: 14, color: AppColors.accent),
                    const SizedBox(width: 4),
                    Text(
                      switch (m.totalReplies) {
                        0 => 'Reply',
                        1 => '1 reply',
                        final n => '$n replies',
                      },
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );

    // The avatar heads a run of one sender's messages; the rest of the run
    // keeps its column so the bubbles line up under the first.
    const avatarSize = 30.0;
    final beingEdited = context.select<ChatConversationCubit, bool>(
        (c) => c.state.editing?.id == m.id);
    Widget row(bool hovering) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: avatarSize,
          child: showHeader
              ? ChatAvatar(message: m, size: avatarSize)
              : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          // A touch screen has no hover: a long press offers the reactions.
          child: reactable && isTouchPlatform
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: (d) =>
                      _pickReaction(context, d.globalPosition, m),
                  child: content,
                )
              : content,
        ),
        // Their slots are kept whether shown or not, so hovering never
        // reflows the bubble.
        if (reactable && !isTouchPlatform)
          Opacity(
            opacity: hovering ? 1 : 0,
            child: Builder(
              builder: (button) => IconButton(
                icon: Icon(Icons.add_reaction_outlined,
                    size: 14, color: c.textTertiary),
                tooltip: 'Add reaction',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tightFor(width: 24, height: 24),
                onPressed: () {
                  final box = button.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  _pickReaction(context,
                      box.localToGlobal(box.size.bottomLeft(Offset.zero)), m);
                },
              ),
            ),
          ),
        // A touch screen has no hover: the pencil stays.
        if (editable)
          Opacity(
            opacity: hovering || isTouchPlatform || beingEdited ? 1 : 0,
            child: IconButton(
              icon: Icon(Icons.edit_outlined,
                  size: isTouchPlatform ? 18 : 14,
                  color: beingEdited ? AppColors.accent : c.textTertiary),
              tooltip: 'Edit',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tightFor(
                  width: isTouchPlatform ? 36 : 24,
                  height: isTouchPlatform ? 36 : 24),
              onPressed: () => cubit.startEdit(m, inThread: inThread),
            ),
          ),
      ],
    );

    return Container(
      margin: isPost
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
          : EdgeInsets.zero,
      padding: EdgeInsets.fromLTRB(
          isPost ? 10 : 12, showHeader ? 8 : 2, 12, isPost ? 8 : 1),
      decoration: isPost
          ? BoxDecoration(
              // A post wears its author's colour like a chat bubble does.
              color: selected || beingEdited ? c.selectionBg : person.bubble,
              border: Border.all(
                  color: selected || beingEdited
                      ? c.selectionBorder
                      : c.separator),
              borderRadius: BorderRadius.circular(8),
            )
          : beingEdited || selected
              ? BoxDecoration(color: c.selectionBg)
              : null,
      child: (editable || reactable) && !isTouchPlatform
          ? _Hover(builder: row)
          : row(false),
    );
  }

  /// The reaction menu at [at]; the emoji picked goes on [m].
  static Future<void> _pickReaction(
      BuildContext context, Offset at, ChatMessage m) async {
    final cubit = context.read<ChatConversationCubit>();
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final emoji = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          at & const Size(1, 1), Offset.zero & overlay.size),
      items: const [_ReactionGrid()],
    );
    if (emoji != null) await cubit.react(m, emoji);
  }
}

/// [quickReactions] as one row of a popup menu; a tap closes the menu with
/// that emoji.
class _ReactionGrid extends PopupMenuEntry<String> {
  const _ReactionGrid();

  @override
  double get height => 40;

  @override
  bool represents(String? value) => false;

  @override
  State<_ReactionGrid> createState() => _ReactionGridState();
}

class _ReactionGridState extends State<_ReactionGrid> {
  @override
  Widget build(BuildContext context) {
    final size = isTouchPlatform ? 40.0 : 30.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: SizedBox(
        width: size * 6,
        child: Wrap(
          children: [
            for (final e in quickReactions)
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => Navigator.of(context).pop(e),
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Center(
                    child: Text(e,
                        style: TextStyle(fontSize: isTouchPlatform ? 22 : 17)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One reaction under a message: outlined when it includes the user's own.
/// When [onTap] is given, a tap adds the user's, or — [own] — takes it off.
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.reaction,
    required this.own,
    required this.onTap,
    required this.child,
  });

  final ChatReaction reaction;
  final bool own;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.badgeBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: own ? AppColors.accent : Colors.transparent),
      ),
      child: child,
    );
    if (onTap == null) return chip;
    return Tooltip(
      message: own
          ? 'Remove your ${reaction.emoji}'
          : 'React with ${reaction.emoji}',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: chip,
      ),
    );
  }
}

/// [builder] told whether the pointer is over it.
class _Hover extends StatefulWidget {
  const _Hover({required this.builder});

  final Widget Function(bool hovering) builder;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: widget.builder(_hovering),
      );
}

class _ThreadPanel extends StatelessWidget {
  const _ThreadPanel({
    required this.post,
    required this.replies,
    required this.loading,
    required this.sending,
    required this.showBack,
    required this.backLabel,
  });

  final String backLabel;
  final ChatMessage? post;
  final List<ChatMessage> replies;
  final bool loading;
  final bool sending;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cubit = context.read<ChatConversationCubit>();
    return Column(
      children: [
        SizedBox(
          height: touchRowHeight(40),
          child: Row(
            children: [
              const SizedBox(width: 4),
              if (showBack)
                IconButton(
                  icon: Icon(Icons.arrow_back_ios_new_rounded,
                      size: touchIcon(14), color: c.textMuted),
                  tooltip: backLabel,
                  onPressed: cubit.closeThread,
                )
              else
                const SizedBox(width: 8),
              Expanded(
                child: Text('Thread',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary)),
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5)),
                ),
              if (!showBack)
                IconButton(
                  icon: Icon(Icons.close,
                      size: touchIcon(14), color: c.textMuted),
                  tooltip: 'Close thread',
                  onPressed: cubit.closeThread,
                ),
            ],
          ),
        ),
        Divider(height: 1, color: c.separator),
        Expanded(
          child: SelectionArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (post != null)
                  _MessageTile(
                      message: post!,
                      showHeader: true,
                      isPost: false,
                      selected: false,
                      inThread: true),
                if (post != null)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Divider(color: c.separator),
                  ),
                for (final r in replies)
                  _MessageTile(
                      message: r,
                      showHeader: true,
                      isPost: false,
                      selected: false,
                      inThread: true),
              ],
            ),
          ),
        ),
        _Composer(hint: 'Reply', sending: sending, inThread: true),
      ],
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.hint,
    required this.sending,
    this.inThread = false,
  });

  final String hint;
  final bool sending;

  /// The open thread's composer: it edits the thread's replies, the other
  /// one everything else.
  final bool inThread;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// What was typed before an edit took the box over, given back after it.
  String? _draft;

  bool _mine(ChatConversationState s) =>
      s.editing != null && s.editingInThread == widget.inThread;

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    final cubit = context.read<ChatConversationCubit>();
    // Decided before the await: only this box's own edit is saved from it.
    if (_mine(cubit.state)) {
      // A saved edit hands the box back through the listener below.
      await cubit.saveEdit(text);
    } else if (await cubit.send(text, inThread: widget.inThread) && mounted) {
      _controller.clear();
    }
    _focus.requestFocus();
  }

  /// Up in an empty box edits the user's newest message, as Slack and Teams
  /// do. Anywhere else Up moves the caret, as always.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.arrowUp ||
        _controller.text.isNotEmpty ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final cubit = context.read<ChatConversationCubit>();
    final last = cubit.lastEditable(inThread: widget.inThread);
    if (last == null) return KeyEventResult.ignored;
    cubit.startEdit(last, inThread: widget.inThread);
    return KeyEventResult.handled;
  }

  void _onEditing(BuildContext context, ChatConversationState s) {
    final editing = _mine(s) ? s.editing : null;
    if (editing != null) {
      _draft ??= _controller.text;
      _controller.value = TextEditingValue(
        text: editing.editableText ?? '',
        selection: TextSelection.collapsed(
            offset: (editing.editableText ?? '').length),
      );
      _focus.requestFocus();
    } else if (_draft != null) {
      _controller.text = _draft!;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
      _draft = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final editing = context.select<ChatConversationCubit, bool>(
        (cubit) => _mine(cubit.state));
    return BlocListener<ChatConversationCubit, ChatConversationState>(
      listenWhen: (a, b) =>
          a.editing?.id != b.editing?.id ||
          a.editingInThread != b.editingInThread,
      listener: _onEditing,
      child: Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.separator)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (editing)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.edit_outlined,
                      size: 13, color: AppColors.accent),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      'Editing message · Esc to cancel',
                      style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                    ),
                  ),
                  InkWell(
                    onTap: context.read<ChatConversationCubit>().cancelEdit,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.close,
                          size: touchIcon(14), color: c.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            // Enter sends; Shift+Enter is a new line. Esc leaves an edit.
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _send,
                const SingleActivator(LogicalKeyboardKey.numpadEnter): _send,
                if (editing)
                  const SingleActivator(LogicalKeyboardKey.escape):
                      context.read<ChatConversationCubit>().cancelEdit,
              },
              child: Focus(
                onKeyEvent: _onKey,
                child: TextField(
                controller: _controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: TextStyle(fontSize: 13, color: c.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.hint,
                  hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
                  filled: true,
                  fillColor: c.surfaceBase,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.separator),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.separator),
                  ),
                ),
              ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: widget.sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(editing ? Icons.check_rounded : Icons.send_rounded,
                    size: 18, color: AppColors.accent),
            tooltip: editing ? 'Save' : 'Send',
            onPressed: widget.sending ? null : _send,
          ),
        ],
      ),
        ],
      ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.errorBannerBg,
        border: Border(bottom: BorderSide(color: c.errorBannerBorder)),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 12, color: c.errorBannerText)),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: c.stateIcon),
            const SizedBox(height: 8),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: c.textTertiary)),
          ],
        ),
      ),
    );
  }
}

/// Shown before a Microsoft 365 or Google Workspace account has consented to
/// chat, and for a Slack workspace that has to be connected again.
class ChatConsentPrompt extends StatelessWidget {
  const ChatConsentPrompt({
    super.key,
    required this.onGrant,
    this.error,
    this.google = false,
    this.slackWorkspace,
  });

  final VoidCallback onGrant;
  final String? error;

  /// Names Google Chat rather than Teams.
  final bool google;

  /// A Slack workspace whose sign-in Slack no longer accepts: the prompt
  /// asks to reconnect it instead.
  final String? slackWorkspace;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 32, color: c.stateIcon),
            const SizedBox(height: 8),
            Text(
              slackWorkspace != null
                  ? 'Slack no longer accepts NightMail\'s sign-in for '
                      '$slackWorkspace. Connect it again to keep chatting.'
                  : google
                  ? 'NightMail needs your permission to read and send '
                      'Google Chat messages.'
                  : 'NightMail needs your permission to read and send Teams '
                      'chats.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: c.textTertiary),
            ),
            const SizedBox(height: 12),
            FilledButton(
                onPressed: onGrant,
                child: Text(
                    slackWorkspace != null ? 'Reconnect Slack' : 'Allow chat')),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: c.errorBannerText)),
            ],
          ],
        ),
      ),
    );
  }
}
