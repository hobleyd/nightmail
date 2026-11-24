import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../core/platform/touch_metrics.dart';
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
        final threadOpen = isChannel && state.threadPostId != null;

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
    required this.canLoadOlder,
    required this.loadingOlder,
    this.selectedPostId,
  });

  final List<ChatMessage> messages;
  final bool isChannel;
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
  });

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
    final body = m.isDeleted
        ? Text('This message was deleted.',
            style: TextStyle(
                fontSize: 13,
                color: c.textMuted,
                fontStyle: FontStyle.italic))
        : ChatMessageBody(
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
          if (m.editedAt != null && !m.isDeleted) ...[
            const SizedBox(width: 6),
            Text('Edited',
                style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
        ],
      ),
    );

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
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: c.badgeBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      r.count > 1 ? '${r.emoji} ${r.count}' : r.emoji,
                      style: const TextStyle(fontSize: 12),
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
        if (isPost)
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
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: avatarSize,
          child: showHeader
              ? ChatAvatar(message: m, size: avatarSize)
              : null,
        ),
        const SizedBox(width: 8),
        Expanded(child: content),
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
              color: selected ? c.selectionBg : person.bubble,
              border: Border.all(
                  color: selected ? c.selectionBorder : c.separator),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: row,
    );
  }
}

class _ThreadPanel extends StatelessWidget {
  const _ThreadPanel({
    required this.post,
    required this.replies,
    required this.loading,
    required this.sending,
    required this.showBack,
  });

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
                  tooltip: 'Back to posts',
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
                      selected: false),
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
                      selected: false),
              ],
            ),
          ),
        ),
        _Composer(hint: 'Reply', sending: sending),
      ],
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({required this.hint, required this.sending});

  final String hint;
  final bool sending;

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

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    final ok = await context.read<ChatConversationCubit>().send(text);
    if (ok && mounted) _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.separator)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            // Enter sends; Shift+Enter is a new line.
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _send,
                const SingleActivator(LogicalKeyboardKey.numpadEnter): _send,
              },
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
          const SizedBox(width: 4),
          IconButton(
            icon: widget.sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded,
                    size: 18, color: AppColors.accent),
            tooltip: 'Send',
            onPressed: widget.sending ? null : _send,
          ),
        ],
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
/// chat.
class ChatConsentPrompt extends StatelessWidget {
  const ChatConsentPrompt({
    super.key,
    required this.onGrant,
    this.error,
    this.google = false,
  });

  final VoidCallback onGrant;
  final String? error;

  /// Names Google Chat rather than Teams.
  final bool google;

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
              google
                  ? 'NightMail needs your permission to read and send '
                      'Google Chat messages.'
                  : 'NightMail needs your permission to read and send Teams '
                      'chats.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: c.textTertiary),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onGrant, child: const Text('Allow chat')),
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
