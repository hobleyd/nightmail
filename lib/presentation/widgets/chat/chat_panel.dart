import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/platform/touch_metrics.dart';
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
import 'chat_conversation_view.dart';
import 'chat_pane_picker.dart';
import 'chat_rename_dialog.dart';
import 'chat_window_target.dart';

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
/// Chats on the system the Chat button's menu chose
/// ([ChatUnreadState.chosen]): the account's own chat, or a Slack workspace —
/// where the people on offer are the ones Slack finds by address.
///
/// The dropdown also offers that system's unread chats
/// ([ChatUnreadState.unreadChats]), under the people, and a field that finds
/// anyone in the address book or any chat or channel ([ChatPanePicker]):
/// picking one of those opens it in place until another email is selected.
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
    // A reconnected Slack workspace drops its "Reconnect" in the menu.
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

    // The chat system: what the button's menu chose, or — before the
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
        (_chatEmailId != email?.id || _chatSourceId != chatId)) {
      _chat = null;
      _picked = null;
    }
    final chat = _chat;
    final picked = _picked;
    final person = picked ??
        candidates.where((p) => p.email == _chosen).firstOrNull ??
        candidates.firstOrNull;

    final people = {for (final p in everyone) p.email};
    final unreadChats = <ChatConversation>[
      for (final c in unreadState.unreadChats[chatId] ?? const [])
        // A one-on-one with someone on the email is already offered as them.
        if (!(c.kind == ChatKind.oneOnOne &&
            c.members.any((m) => people.contains(m.email))))
          c,
    ];
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
                  Tooltip(
                    message: source?.label ?? 'Chat',
                    child: Icon(
                        source != null && source.isSlack
                            ? Icons.tag_rounded
                            : Icons.forum_outlined,
                        size: touchIcon(16),
                        color: AppColors.accent),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: chatId != null &&
                            account != null &&
                            (_access == ChatAccess.chatsOnly ||
                                _access == ChatAccess.full)
                        ? ChatPanePicker(
                            chatId: chatId,
                            account: account,
                            people: candidates,
                            chats: unreadChats,
                            selectedPerson: chat == null ? person : null,
                            selectedChat: chat,
                            onPerson: (p) => setState(() {
                              _chat = null;
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
                              _chatEmailId = email?.id;
                              _chatSourceId = chatId;
                            }),
                          )
                        : Text(
                            chat?.title ?? person?.label ?? 'Chat',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
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
          Expanded(child: body),
        ],
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
