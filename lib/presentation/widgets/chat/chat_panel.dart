import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/platform/touch_metrics.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/platform/window_utils.dart';
import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/chat.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/repositories/chat_repository.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../injection_container.dart';
import '../../blocs/account/account_cubit.dart';
import '../../blocs/chat/chat_conversation_cubit.dart';
import '../../blocs/chat/chat_unread_cubit.dart';
import '../../blocs/email_detail/email_detail_bloc.dart';
import '../../blocs/email_detail/email_detail_state.dart';
import 'chat_conversation_row.dart';
import 'chat_conversation_view.dart';
import 'chat_pane_picker.dart';
import 'chat_rename_dialog.dart';
import 'chat_source_picker.dart';
import 'chat_window_target.dart';
import '../../../core/platform/platform.dart';

/// The Chat pane beside the reading pane: a one-on-one with the selected
/// email's sender, or — from the dropdown — with anyone else on it who is in
/// the account's organisation or already has a one-on-one with the account.
/// Other outsiders are left out: whether Teams or Google Chat would let a chat
/// be started with them can't be known without trying
/// ([ChatRepository.reachable]).
///
/// Follows the selection: a new email points the pane at its sender, unless
/// the person already chosen is on that email too. Never creates a chat by
/// being opened; see [ChatPerson].
///
/// Chats on the system picked in the pane's header
/// ([ChatUnreadState.chosen]): the account's own chat, or a Slack workspace —
/// where the people on offer are the ones Slack finds by address.
///
/// Laid out top to bottom: the system (a dropdown when there is more than
/// one, [ChatSourcePicker]); its unread chats and channels, newest first, in
/// the top 30% ([ChatUnreadState.unreadChats]) — one clicked stays open across
/// emails; then a bar with the email's people and a field that finds anyone
/// in the address book or any chat or channel ([ChatPanePicker]) — picked
/// there, it lasts until another email is selected; and the conversation.
class ChatPanel extends StatelessWidget {
  const ChatPanel({
    super.key,
    required this.onClose,
    this.useBackNavigation = false,
  });

  final VoidCallback onClose;
  final bool useBackNavigation;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<ChatConversationCubit>(),
      child: _ChatPanelBody(
        onClose: onClose,
        useBackNavigation: useBackNavigation,
      ),
    );
  }
}

class _ChatPanelBody extends StatefulWidget {
  const _ChatPanelBody({
    required this.onClose,
    required this.useBackNavigation,
  });

  final VoidCallback onClose;
  final bool useBackNavigation;

  @override
  State<_ChatPanelBody> createState() => _ChatPanelBodyState();
}

class _ChatPanelBodyState extends State<_ChatPanelBody> {
  String? _accountId;
  ChatAccess? _access;
  String? _consentError;

  /// The address chosen in the dropdown, kept across emails while it is on
  /// them.
  String? _chosen;

  /// A chat, or a person not on the email, picked from the dropdown, and
  /// the email it was picked on: a new email goes back to its people.
  ChatConversation? _chat;
  ChatPerson? _picked;
  String? _chatEmailId;

  /// The unread list's share of the pane under the header, dragged at the
  /// divider; [AppSettings.loadChatPaneSplit] across launches, and held here
  /// so a pane reopened this session needs no read.
  static double? _savedSplit;
  double _split = _savedSplit ?? AppSettings.defaultChatPaneSplit;

  @override
  void initState() {
    super.initState();
    if (_savedSplit == null && sl.isRegistered<AppSettings>()) {
      sl<AppSettings>().loadChatPaneSplit().then((v) {
        _savedSplit ??= v;
        if (mounted) setState(() => _split = _savedSplit!);
      });
    }
  }

  void _saveSplit() {
    _savedSplit = _split;
    if (sl.isRegistered<AppSettings>()) {
      unawaited(sl<AppSettings>().saveChatPaneSplit(_split));
    }
  }

  /// [_chat] came from the unread list: it stays open across emails until
  /// something else is picked or the system changes.
  bool _held = false;

  /// What the conversation cubit was last pointed at: `account|address`.
  String? _openedKey;

  /// Which of the current email's people can be chatted with, for
  /// `account|email` [_colleaguesKey]; null while that is being looked up.
  Set<String>? _colleagues;
  String? _colleaguesKey;

  void _checkColleagues(String accountId, String key, List<ChatPerson> all) {
    _colleaguesKey = key;
    _colleagues = null;
    unawaited(sl<ChatRepository>()
        .reachable(accountId, [
          for (final p in all) (email: p.email, name: p.name),
        ])
        .then((found) {
      if (mounted && _colleaguesKey == key) {
        setState(() => _colleagues = found);
      }
    }));
  }

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// Everyone on [email] but the account itself: the sender first, then To
  /// and Cc, each address once.
  static List<ChatPerson> candidatesFor(Email? email, Account account) {
    if (email == null) return const [];
    final own = account.allAddresses;
    final seen = <String>{};
    return [
      for (final a in [
        email.from,
        ...email.toRecipients,
        ...email.ccRecipients,
      ])
        if (a.address.trim().isNotEmpty &&
            !own.contains(a.address.trim().toLowerCase()) &&
            seen.add(a.address.trim().toLowerCase()))
          ChatPerson(
            email: a.address.trim().toLowerCase(),
            name: (a.name ?? '').trim(),
          ),
    ];
  }

  /// The chat window, on this pane's system and — when one is open — its
  /// conversation (a person with no chat yet opens just the system).
  void _openWindow() {
    final state = context.read<ChatConversationCubit>().state;
    final sourceId = state.accountId ?? _accountId;
    if (sourceId == null) {
      unawaited(showOrCreateSubWindow(ChatWindowTarget.windowType));
      return;
    }
    unawaited(openChatWindow(ChatWindowTarget(
        sourceId: sourceId, conversation: state.conversation)));
  }

  /// Renames the open conversation; the picker's label follows.
  Future<void> _rename() async {
    final cubit = context.read<ChatConversationCubit>();
    final conversation = cubit.state.conversation;
    if (conversation == null) return;
    final renamed = await showChatRenameDialog(context,
        conversation: conversation, rename: cubit.rename);
    final now = cubit.state.conversation;
    if (!renamed || !mounted || now == null) return;
    if (_chat?.key == now.key) setState(() => _chat = now);
  }

  Future<void> _sync(
      String accountId, ChatPerson? person, ChatConversation? chat) async {
    final cubit = context.read<ChatConversationCubit>();
    if (accountId != _accountId) {
      _accountId = accountId;
      _access = null;
      _openedKey = null;
      final access = await cubit.checkAccess(accountId);
      if (!mounted || _accountId != accountId) return;
      setState(() => _access = access);
    }
    final access = _access;
    if (access == null ||
        access == ChatAccess.unsupported ||
        access == ChatAccess.needsConsent) {
      return;
    }
    final key = chat != null
        ? '$accountId|chat:${chat.key}'
        : person == null
            ? null
            : '$accountId|${person.email}';
    if (key == _openedKey) return;
    _openedKey = key;
    if (chat != null) {
      unawaited(cubit.open(accountId, chat));
    } else if (person == null) {
      cubit.clear();
    } else {
      unawaited(cubit.openPerson(accountId, person));
    }
  }

  /// The chat system [_chat] or [_picked] was picked on.
  String? _chatSourceId;

  Future<void> _grant() async {
    final accountId = _accountId;
    if (accountId == null) return;
    final unread = context.read<ChatUnreadCubit>();
    setState(() => _consentError = null);
    final access = await context
        .read<ChatConversationCubit>()
        .requestAccess(accountId);
    if (!mounted) return;
    if (access == null) {
      setState(() => _consentError =
          context.read<ChatConversationCubit>().state.error ??
              'Chat was not allowed.');
      return;
    }
    setState(() {
      _access = access;
      _openedKey = null;
    });
    // A reconnected Slack workspace drops its "Reconnect" in the dropdown.
    unawaited(unread.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accountState = context.watch<AccountCubit>().state;
    final account =
        accountState is AccountsLoaded ? accountState.activeAccount : null;
    final detail = context.watch<EmailDetailBloc>().state;
    final email = detail is EmailDetailLoaded ? detail.email : null;

    // The chat system: what the header's dropdown chose, or — before the
    // systems are known, or for an account with none — the account itself,
    // whose access check then explains what is missing.
    final unreadState = context.watch<ChatUnreadCubit>().state;
    final source = unreadState.chosen;
    final chatId = source?.id ?? account?.id;
    final everyone =
        account == null ? const <ChatPerson>[] : candidatesFor(email, account);
    if (chatId != null) {
      final key = '$chatId|${email?.id}';
      if (key != _colleaguesKey) _checkColleagues(chatId, key, everyone);
    }
    final colleagues = _colleagues;
    final candidates = colleagues == null
        ? const <ChatPerson>[]
        : everyone.where((p) => colleagues.contains(p.email)).toList();
    // A chat or person picked on another email, or on another chat system,
    // is let go.
    if ((_chat != null || _picked != null) &&
        (_chatSourceId != chatId || (!_held && _chatEmailId != email?.id))) {
      _chat = null;
      _picked = null;
      _held = false;
    }
    final chat = _chat;
    final picked = _picked;
    final person = picked ??
        candidates.where((p) => p.email == _chosen).firstOrNull ??
        candidates.firstOrNull;

    final unreadChats = [
      ...unreadState.unreadChats[chatId] ?? const <ChatConversation>[],
    ];
    if (chat != null && _held && !unreadChats.any((u) => u.key == chat.key)) {
      unreadChats.add(chat);
    }
    unreadChats.sort((a, b) {
      final at = a.lastActivity, bt = b.lastActivity;
      if (at == null || bt == null) return at == null ? (bt == null ? 0 : 1) : -1;
      return bt.compareTo(at);
    });
    if (chatId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync(chatId, person, chat);
      });
    }

    final Widget body;
    if (account == null || _access == null) {
      body = const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppColors.accent),
        ),
      );
    } else if (_access == ChatAccess.unsupported) {
      body = _PaneNotice(
        text: account is GmailAccount
            ? 'Google Chat is available for Google Workspace accounts, not '
                'personal Gmail.'
            : 'Chat is available for Microsoft 365, NightMail Server and '
                'Google Workspace accounts, and for Slack once a workspace is '
                'connected in Settings > General.',
      );
    } else if (_access == ChatAccess.needsConsent) {
      body = ChatConsentPrompt(
        onGrant: _grant,
        error: _consentError,
        google: account is GmailAccount,
        slackWorkspace: source != null && source.isSlack && source.id == chatId
            ? source.label.replaceFirst('Slack · ', '')
            : null,
      );
    } else if (chat != null || picked != null) {
      body = const ChatConversationView();
    } else if (everyone.isNotEmpty && colleagues == null) {
      body = const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppColors.accent),
        ),
      );
    } else if (person == null) {
      body = _PaneNotice(
          text: everyone.isEmpty
              ? 'Select an email to chat with the people on it, or find '
                  'anyone above.'
              : source != null && source.isSlack
                  ? 'Nobody on this email is in ${source.label}.'
                  : 'Nobody on this email is in your organisation or has '
                      'chatted with you.');
    } else {
      body = const ChatConversationView();
    }

    final hasChat =
        _access == ChatAccess.chatsOnly || _access == ChatAccess.full;
    final ready = hasChat && chatId != null && account != null;

    return ColoredBox(
      color: c.surfacePanel,
      child: Column(
        children: [
          SizedBox(
            height: touchRowHeight(48),
            child: Padding(
              padding: widget.useBackNavigation
                  ? const EdgeInsets.fromLTRB(4, 0, 8, 0)
                  : const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  if (widget.useBackNavigation) ...[
                    IconButton(
                      icon: Icon(Icons.arrow_back_ios_new_rounded,
                          size: touchIcon(16), color: c.textMuted),
                      tooltip: 'Back',
                      onPressed: widget.onClose,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ChatSourcePicker(
                        sources: unreadState.sources,
                        chosen: source,
                        unreadIn: unreadState.unreadIn,
                        onChoose: context.read<ChatUnreadCubit>().choose,
                      ),
                    ),
                  ),
                  if (_isDesktop)
                    IconButton(
                      icon: Icon(Icons.open_in_new_rounded,
                          size: touchIcon(15), color: c.textMuted),
                      tooltip: 'Open chat window',
                      onPressed: _openWindow,
                    ),
                  if (!widget.useBackNavigation)
                    IconButton(
                      icon: Icon(Icons.close,
                          size: touchIcon(16), color: c.textMuted),
                      tooltip: 'Close',
                      onPressed: widget.onClose,
                    ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: c.separatorStrong),
          Expanded(
            child: !ready
                ? body
                : LayoutBuilder(
                    builder: (context, box) {
                      // At least a row of the list; the conversation keeps
                      // room for its bar, a message and the composer.
                      final hi = math.max(
                          _minUnread, box.maxHeight - _minConversation);
                      final top =
                          (box.maxHeight * _split).clamp(_minUnread, hi);
                      return Column(
                      children: [
                        SizedBox(
                          height: top,
                          child: _UnreadList(
                            chats: unreadChats,
                            selected: chat,
                            onTap: (u) => setState(() {
                              _chat = u;
                              _picked = null;
                              _held = true;
                              _chatEmailId = email?.id;
                              _chatSourceId = chatId;
                            }),
                          ),
                        ),
                        _SplitHandle(
                          onDrag: (dy) => setState(() => _split =
                              ((top + dy).clamp(_minUnread, hi)) /
                                  box.maxHeight),
                          onEnd: _saveSplit,
                        ),
                        _conversationBar(
                          c: c,
                          chatId: chatId,
                          account: account,
                          email: email,
                          candidates: candidates,
                          person: person,
                          chat: chat,
                        ),
                        Divider(height: 1, color: c.separator),
                        Expanded(child: body),
                      ],
                    );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Above the conversation: who or what it is — the email's people and
  /// "find anyone" ([ChatPanePicker]) — and Rename.
  Widget _conversationBar({
    required AppColors c,
    required String chatId,
    required Account account,
    required Email? email,
    required List<ChatPerson> candidates,
    required ChatPerson? person,
    required ChatConversation? chat,
  }) {
    return SizedBox(
      height: touchRowHeight(36),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: ChatPanePicker(
                chatId: chatId,
                account: account,
                people: candidates,
                chats: const [],
                selectedPerson: chat == null ? person : null,
                selectedChat: chat,
                onPerson: (p) => setState(() {
                  _chat = null;
                  _held = false;
                  if (candidates.any((c) => c.email == p.email)) {
                    _chosen = p.email;
                    _picked = null;
                  } else {
                    _picked = p;
                    _chatEmailId = email?.id;
                    _chatSourceId = chatId;
                  }
                }),
                onChat: (c) => setState(() {
                  _chat = c;
                  _picked = null;
                  _held = false;
                  _chatEmailId = email?.id;
                  _chatSourceId = chatId;
                }),
              ),
            ),
            BlocBuilder<ChatConversationCubit, ChatConversationState>(
              buildWhen: (a, b) =>
                  a.accountId != b.accountId ||
                  a.conversation != b.conversation,
              builder: (context, _) =>
                  context.read<ChatConversationCubit>().canRename
                      ? IconButton(
                          icon: Icon(Icons.edit_outlined,
                              size: touchIcon(15), color: c.textMuted),
                          tooltip: 'Rename',
                          onPressed: _rename,
                        )
                      : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

const double _minUnread = 56;
const double _minConversation = 180;

/// The divider between the unread list and the conversation: drag it up or
/// down (mouse or touch); the split is saved when the drag ends.
class _SplitHandle extends StatefulWidget {
  const _SplitHandle({required this.onDrag, required this.onEnd});

  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;

  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => setState(() => _dragging = true),
        onVerticalDragUpdate: (d) => widget.onDrag(d.delta.dy),
        onVerticalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onEnd();
        },
        onVerticalDragCancel: () => setState(() => _dragging = false),
        child: SizedBox(
          height: isTouchPlatform ? 20 : 8,
          child: Center(
            child: Container(
              height: active ? 2 : 1,
              color: active ? c.textDimmed : c.separatorStrong,
            ),
          ),
        ),
      ),
    );
  }
}

/// The top of the pane: the chosen system's unread chats and channels,
/// newest first. The open one stays listed, highlighted, once it is read.
class _UnreadList extends StatelessWidget {
  const _UnreadList({
    required this.chats,
    required this.selected,
    required this.onTap,
  });

  final List<ChatConversation> chats;
  final ChatConversation? selected;
  final ValueChanged<ChatConversation> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (chats.isEmpty) {
      return Center(
        child: Text('No unread chats',
            style: TextStyle(fontSize: 12.5, color: c.textTertiary)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: chats.length,
      itemBuilder: (context, i) => ChatConversationRow(
        conversation: chats[i],
        selected: chats[i].key == selected?.key,
        onTap: () => onTap(chats[i]),
      ),
    );
  }
}

class _PaneNotice extends StatelessWidget {
  const _PaneNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: c.textTertiary)),
      ),
    );
  }
}
