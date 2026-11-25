import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../core/platform/touch_metrics.dart';
import '../../../core/platform/clipboard_image.dart';
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
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
    // Reply opens the thread with its box ready to type in. Beside the
    // list the thread composer already exists, so a newly opened thread
    // (the listener below) focuses it too; on a narrow screen it is built
    // as the thread opens.
    if (widget.inThread) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---- @ typeahead ---------------------------------------------------------

  /// People picked from the typeahead for the message being typed. Only
  /// those still written as `@Name` at send are tagged (`splitMentions`).
  final _picked = <ChatMember>[];

  /// Who the open conversation can tag, once asked; null before the first
  /// `@`, and again after the conversation changes.
  List<ChatMember>? _roster;
  bool _askingRoster = false;

  /// The `@` [_roster] was last asked for. Each new `@` asks the cubit
  /// again — its network roster is cached there, and the senders it adds
  /// change as people write.
  int? _rosterAt;

  /// The open list: matches for what follows the `@` at [_at].
  List<ChatMember> _matches = const [];
  int _highlight = 0;
  int? _at;

  /// The `@` whose list Esc closed — not reopened while it is being typed.
  int? _dismissedAt;

  static const _maxMatches = 6;

  bool get _suggesting => _matches.isNotEmpty;

  /// Opens, narrows or closes the list as the text or caret moves: open
  /// while the caret follows an `@` that starts a word (so an address's `@`
  /// never opens it), on one line, a few words at most. Never in an edit —
  /// a save is text only.
  void _onTyped() {
    final query = _mentionQuery();
    if (query == null) {
      _close();
      return;
    }
    final (at, typed) = query;
    final roster = _roster;
    if (roster == null || at != _rosterAt) {
      _askRoster(at);
      if (roster == null) return;
    }
    final matches = matchMentions(roster, typed, limit: _maxMatches);
    if (matches.isEmpty) {
      _close();
      return;
    }
    setState(() {
      if (_at != at || !_sameMembers(matches, _matches)) _highlight = 0;
      _at = at;
      _matches = matches;
    });
  }

  (int, String)? _mentionQuery() {
    final value = _controller.value;
    final sel = value.selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    if (_mine(context.read<ChatConversationCubit>().state)) return null;
    final caret = sel.baseOffset;
    final text = value.text;
    if (caret <= 0 || caret > text.length) return null;
    final at = text.lastIndexOf('@', caret - 1);
    if (at < 0) return null;
    if (at == _dismissedAt) {
      // Esc closed this `@`; once it is deleted, the next one may open.
      if (text.length > at && text[at] == '@') return null;
      _dismissedAt = null;
    }
    if (at > 0 && !RegExp(r'[\s(]').hasMatch(text[at - 1])) return null;
    final typed = text.substring(at + 1, caret);
    if (typed.contains('\n') ||
        typed.startsWith(' ') ||
        typed.length > 40 ||
        typed.split(' ').length > 3) {
      return null;
    }
    return (at, typed);
  }

  Future<void> _askRoster(int at) async {
    if (_askingRoster) return;
    _askingRoster = true;
    _rosterAt = at;
    final cubit = context.read<ChatConversationCubit>();
    final conversation = cubit.state.conversation?.id;
    final roster = await cubit.mentionable();
    _askingRoster = false;
    if (!mounted || cubit.state.conversation?.id != conversation) return;
    // Nobody yet (a conversation still loading): asked again on the next `@`.
    if (roster.isNotEmpty) _roster = roster;
    if (_roster != null) _onTyped();
  }

  void _close() {
    if (_matches.isEmpty && _at == null) return;
    setState(() {
      _matches = const [];
      _at = null;
      _highlight = 0;
    });
  }

  /// Puts `@Name ` in place of what was typed after the `@`.
  void _pick(ChatMember m) {
    final at = _at;
    if (at == null) return;
    final value = _controller.value;
    final caret = value.selection.baseOffset;
    final name = m.displayName.trim();
    final text = value.text.replaceRange(at, caret, '@$name ');
    if (!_picked.any((p) => p.userId == m.userId)) _picked.add(m);
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: at + name.length + 2),
    );
    _close();
    _focus.requestFocus();
  }

  /// Up/Down move through the list, Enter or Tab picks, Esc closes it —
  /// handled before the box's own Enter (send) and Esc (leave an edit, drop
  /// a picture) see them.
  KeyEventResult _onSuggestKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() =>
          _highlight = (_highlight + step) % _matches.length);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      _pick(_matches[_highlight.clamp(0, _matches.length - 1)]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _dismissedAt = _at;
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Forgets the picks and the roster: another conversation, or a thread
  /// that is not this one's.
  void _resetMentions() {
    _picked.clear();
    _roster = null;
    _rosterAt = null;
    _dismissedAt = null;
    _close();
  }

  static bool _sameMembers(List<ChatMember> a, List<ChatMember> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  /// What was typed before an edit took the box over, given back after it.
  String? _draft;

  bool _mine(ChatConversationState s) =>
      s.editing != null && s.editingInThread == widget.inThread;

  /// A pasted picture waiting to go with the next send.
  ChatOutgoingImage? _image;

  Future<void> _send() async {
    final text = _controller.text;
    final cubit = context.read<ChatConversationCubit>();
    // Decided before the await: only this box's own edit is saved from it.
    if (_mine(cubit.state)) {
      if (text.trim().isEmpty) return;
      // A saved edit hands the box back through the listener below.
      await cubit.saveEdit(text);
    } else {
      final image = _image;
      if (text.trim().isEmpty && image == null) return;
      if (await cubit.send(text,
              inThread: widget.inThread,
              image: image,
              mentions: List.of(_picked)) &&
          mounted) {
        _controller.clear();
        _picked.clear();
        _dismissedAt = null;
        setState(() => _image = null);
      }
    }
    _focus.requestFocus();
  }

  /// Cmd+V with a picture on the clipboard stages it under the box, where
  /// the conversation can take one; anything else pastes as text. An edit
  /// is text only.
  Future<bool> _pasteImage() async {
    final cubit = context.read<ChatConversationCubit>();
    if (_mine(cubit.state) || !cubit.canSendImage) return false;
    final found = await readClipboardImage();
    if (found == null || !mounted) return false;
    setState(() => _image = ChatOutgoingImage(
          bytes: found.bytes,
          mimeType: found.mimeType,
          name: found.name,
          width: found.width,
          height: found.height,
        ));
    return true;
  }

  /// Up in an empty box edits the user's newest message, as Slack and Teams
  /// do. Anywhere else Up moves the caret, as always.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_suggesting) return _onSuggestKey(event);
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
    return MultiBlocListener(
      listeners: [
        BlocListener<ChatConversationCubit, ChatConversationState>(
          listenWhen: (a, b) =>
              a.editing?.id != b.editing?.id ||
              a.editingInThread != b.editingInThread,
          listener: _onEditing,
        ),
        if (widget.inThread)
          BlocListener<ChatConversationCubit, ChatConversationState>(
            listenWhen: (a, b) =>
                b.threadPostId != null && a.threadPostId != b.threadPostId,
            listener: (_, _) => _focus.requestFocus(),
          ),
        // A picture pasted for one conversation never goes to the next,
        // nor do the people tagged for it.
        BlocListener<ChatConversationCubit, ChatConversationState>(
          listenWhen: (a, b) =>
              a.accountId != b.accountId ||
              a.conversation?.id != b.conversation?.id ||
              a.threadPostId != b.threadPostId && widget.inThread,
          listener: (_, _) {
            _resetMentions();
            if (_image != null) setState(() => _image = null);
          },
        ),
      ],
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
          if (_image case final image?)
            _PendingImage(
              image: image,
              onRemove: () => setState(() => _image = null),
            ),
          if (_suggesting)
            _MentionList(
              matches: _matches,
              highlight: _highlight,
              onPick: _pick,
              onHover: (i) => setState(() => _highlight = i),
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
                      context.read<ChatConversationCubit>().cancelEdit
                else if (_image != null)
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      setState(() => _image = null),
              },
              child: Actions(
                actions: {PasteTextIntent: _ImagePasteAction(_pasteImage)},
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

/// Who a composer's `@[typed]` could mean, best first: a name starting with
/// it, then one with every typed word starting a word of the name (`@lee`,
/// `@ann l` for "Ann Lee"), then an address starting with it — at most
/// [limit]. Bare `@` lists everyone, in [roster]'s order.
@visibleForTesting
List<ChatMember> matchMentions(List<ChatMember> roster, String typed,
    {int limit = 6}) {
  final q = typed.trim().toLowerCase();
  if (q.isEmpty) return roster.take(limit).toList();
  final words = q.split(RegExp(r'\s+'));
  int? rank(ChatMember m) {
    final name = m.displayName.toLowerCase();
    if (name.startsWith(q)) return 0;
    final parts = name.split(RegExp(r'[\s,.\-]+'));
    if (words.every((w) => parts.any((p) => p.startsWith(w)))) return 1;
    if (m.email?.startsWith(q) ?? false) return 2;
    return null;
  }

  final ranked = [
    for (final m in roster)
      if (rank(m) case final r?) (r, m),
  ];
  // Stable: equal ranks keep the roster's order (members, then senders).
  final sorted = [
    for (var r = 0; r <= 2; r++)
      for (final e in ranked)
        if (e.$1 == r) e.$2,
  ];
  return sorted.take(limit).toList();
}

/// The `@` typeahead above the box. Its rows are part of the field's tap
/// region, so tapping one does not take focus from the field (and drop the
/// phone's keyboard) before the pick lands.
class _MentionList extends StatelessWidget {
  const _MentionList({
    required this.matches,
    required this.highlight,
    required this.onPick,
    required this.onHover,
  });

  final List<ChatMember> matches;
  final int highlight;
  final ValueChanged<ChatMember> onPick;
  final ValueChanged<int> onHover;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return TextFieldTapRegion(
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: c.surfaceBase,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.separator),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, m) in matches.indexed)
              MouseRegion(
                // Movement only: a row that opens under a resting pointer
                // must not take the highlight from the best match.
                onHover: (_) {
                  if (i != highlight) onHover(i);
                },
                child: InkWell(
                  key: ValueKey('mention-${m.userId}'),
                  onTap: () => onPick(m),
                  child: Container(
                    color: i == highlight
                        ? AppColors.accent.withValues(alpha: 0.14)
                        : null,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Row(
                      children: [
                        ChatAvatar(
                          size: 22,
                          message: ChatMessage(
                            id: '',
                            createdAt: DateTime(2000),
                            senderName: m.displayName,
                            senderUserId: m.userId,
                            bodyHtml: '',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            m.displayName,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(fontSize: 13, color: c.textPrimary),
                          ),
                        ),
                        if (m.email case final email?) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              email,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11.5, color: c.textTertiary),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Cmd+V in the composer: asks [onPaste] for a picture first and, when it
/// takes none, pastes text as the field always does. The field's own paste
/// is overridable; it is only reachable while [invoke] runs, so it is taken
/// before the clipboard is read.
class _ImagePasteAction extends Action<PasteTextIntent> {
  _ImagePasteAction(this.onPaste);

  final Future<bool> Function() onPaste;

  @override
  Object? invoke(PasteTextIntent intent) {
    final text = callingAction;
    onPaste().then((taken) {
      if (!taken && text != null && text.isEnabled(intent)) {
        text.invoke(intent);
      }
    });
    return null;
  }
}

/// The pasted picture above the box, with × to drop it.
class _PendingImage extends StatelessWidget {
  const _PendingImage({required this.image, required this.onRemove});

  final ChatOutgoingImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        // The × overlaps the corner from inside the Stack: a child outside
        // its bounds is drawn but never hit.
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7, right: 7),
              child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: c.separator),
                  borderRadius: BorderRadius.circular(6),
                ),
                // Never smaller than the × it carries, even a 1-pixel image.
                constraints: const BoxConstraints(
                    minWidth: 36, minHeight: 36, maxHeight: 96, maxWidth: 200),
                child: Image.memory(
                  image.bytes,
                  fit: BoxFit.contain,
                  semanticLabel: 'Pasted picture',
                  errorBuilder: (_, _, _) => Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(image.name,
                        style: TextStyle(
                            fontSize: 11.5, color: c.textSecondary)),
                  ),
                ),
              ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: Tooltip(
                message: 'Remove picture',
                child: InkWell(
                  onTap: onRemove,
                  customBorder: const CircleBorder(),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: c.surfaceBase,
                      shape: BoxShape.circle,
                      border: Border.all(color: c.separator),
                    ),
                    child: Icon(Icons.close,
                        size: touchIcon(12), color: c.textSecondary),
                  ),
                ),
              ),
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
