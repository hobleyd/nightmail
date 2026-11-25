import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/platform/touch_metrics.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/consumer_email_domain.dart';
import '../../core/utils/latest_reply.dart' show htmlToPlainText;
import '../../domain/entities/chat.dart';
import '../../domain/repositories/chat_repository.dart';
import '../../infrastructure/accounts/account.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/chat/chat_conversation_cubit.dart';
import '../blocs/chat/chat_list_cubit.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';
import '../widgets/chat/chat_conversation_view.dart';

/// The chat window, opened by double-clicking the Chat button: every chat
/// and channel on the left, grouped and newest first, the open one's history
/// on the right, search across them all.
///
/// It opens on the active account's own chat (Teams, Google Chat, NightMail
/// Server); connected Slack workspaces are further entries in its picker,
/// and the one it opens on when the account has no chat of its own.
class ChatWindowApp extends StatelessWidget {
  const ChatWindowApp({super.key});

  static final _darkTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C83FD),
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
  );

  static final _lightTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C83FD),
    ),
    useMaterial3: true,
  );

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<ThemeCubit>(create: (_) => sl<ThemeCubit>()..load()),
        BlocProvider.value(value: sl<AccountCubit>()..initialize()),
        BlocProvider(create: (_) => sl<ChatListCubit>()),
        BlocProvider(create: (_) => sl<ChatConversationCubit>()),
      ],
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          return MaterialApp(
            title: 'Chat',
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: switch (themeState.mode) {
              AppThemeMode.light => ThemeMode.light,
              AppThemeMode.dark => ThemeMode.dark,
              AppThemeMode.system => ThemeMode.system,
            },
            home: const _ChatWindowPage(),
          );
        },
      ),
    );
  }
}

class _ChatWindowPage extends StatefulWidget {
  const _ChatWindowPage();

  @override
  State<_ChatWindowPage> createState() => _ChatWindowPageState();
}

class _ChatWindowPageState extends State<_ChatWindowPage> {
  String? _accountId;
  double _listWidth = 300;

  /// Connected Slack workspaces; null until read from the Keychain, which
  /// this window — its own isolate — does itself.
  List<ChatSource>? _slack;
  StreamSubscription<void>? _slackChanges;

  @override
  void initState() {
    super.initState();
    final repo = sl<ChatRepository>();
    _slackChanges = repo.sourcesChanged.listen((_) => _loadSlack());
    _loadSlack();
  }

  @override
  void dispose() {
    _slackChanges?.cancel();
    super.dispose();
  }

  Future<void> _loadSlack() async {
    final slack = await sl<ChatRepository>().sources(null);
    if (mounted) setState(() => _slack = slack);
  }

  /// Accounts that can chat: Microsoft 365 and NightMail Server sign-ins,
  /// and Google Workspace ones. A shared mailbox has no chats of its own, and
  /// Google's Chat API does not serve `@gmail.com`.
  static List<Account> _chatAccounts(AccountState s) => s is AccountsLoaded
      ? s.accounts
          .where((a) => switch (a) {
                MicrosoftAccount() => !a.isSharedMailbox,
                GmailAccount() => !isConsumerGoogleAddress(a.emailAddress),
                _ => false,
              })
          .toList()
      : const [];

  /// The picker's entries: each account that can chat, then each Slack
  /// workspace.
  List<({String id, String label})> _entries(AccountState s) => [
        for (final a in _chatAccounts(s))
          (
            id: a.id,
            label: a.emailAddress.isNotEmpty ? a.emailAddress : a.displayName,
          ),
        for (final w in _slack ?? const <ChatSource>[])
          (
            id: w.id,
            label: w.needsReconnect ? '${w.label} (reconnect)' : w.label,
          ),
      ];

  /// Starts on the active account's own chat — the platform chat — and only
  /// on Slack when the account has none.
  void _ensureAccount(AccountState s) {
    final entries = _entries(s);
    if (entries.isEmpty) return;
    if (_accountId != null && entries.any((e) => e.id == _accountId)) return;
    final active = s is AccountsLoaded ? s.activeAccount : null;
    // Runs after a frame, so the picker only shows the choice by being
    // rebuilt with it.
    if (entries.any((e) => e.id == active?.id)) {
      setState(() => _switchTo(active!.id));
      return;
    }
    // The active account has no chat: Slack, as the button would — once the
    // workspaces are known, or another account would win the race.
    final slack = _slack;
    if (slack == null) return;
    setState(() => _switchTo(slack.firstOrNull?.id ?? entries.first.id));
  }

  void _switchTo(String accountId) {
    _accountId = accountId;
    context.read<ChatConversationCubit>().clear();
    unawaited(context.read<ChatListCubit>().load(accountId));
    unawaited(context.read<ChatConversationCubit>().checkAccess(accountId));
  }

  void _open(ChatConversation c) {
    final accountId = _accountId;
    if (accountId == null) return;
    context.read<ChatListCubit>().select(c.key);
    unawaited(context.read<ChatConversationCubit>().open(accountId, c));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accountState = context.watch<AccountCubit>().state;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureAccount(context.read<AccountCubit>().state);
    });
    final accounts = _chatAccounts(accountState);
    final entries = _entries(accountState);
    final slack = _slack?.where((w) => w.id == _accountId).firstOrNull;

    if (accountState is AccountsLoaded && _slack != null && entries.isEmpty) {
      return Scaffold(
        backgroundColor: c.surfacePanel,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Chat is available for Microsoft 365, NightMail Server and '
              'Google Workspace accounts, and for Slack once a workspace is '
              'connected in Settings > General.',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textTertiary),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: c.surfacePanel,
      body: LayoutBuilder(builder: (context, constraints) {
        final listWidth =
            _listWidth.clamp(220.0, (constraints.maxWidth - 320).clamp(220.0, 600.0));
        return Row(
          children: [
            SizedBox(
              width: listWidth,
              child: _ConversationList(
                accounts: entries,
                accountId: _accountId,
                onAccountChanged: (id) => setState(() => _switchTo(id)),
                onOpen: _open,
              ),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) =>
                    setState(() => _listWidth = listWidth + d.delta.dx),
                child: SizedBox(
                  width: 5,
                  child: Center(
                    child: VerticalDivider(width: 1, color: c.separatorStrong),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _ConversationPane(
                google: accounts
                    .any((a) => a.id == _accountId && a is GmailAccount),
                slackWorkspace: slack?.label.replaceFirst('Slack · ', ''),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _ConversationList extends StatefulWidget {
  const _ConversationList({
    required this.accounts,
    required this.accountId,
    required this.onAccountChanged,
    required this.onOpen,
  });

  final List<({String id, String label})> accounts;
  final String? accountId;
  final ValueChanged<String> onAccountChanged;
  final ValueChanged<ChatConversation> onOpen;

  @override
  State<_ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<_ConversationList> {
  final _search = TextEditingController();
  final _collapsed = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _searchField(BuildContext context) {
    final c = context.colors;
    return TextField(
      controller: _search,
      style: TextStyle(fontSize: 13, color: c.textPrimary),
      textInputAction: TextInputAction.search,
      onSubmitted: (q) => context.read<ChatListCubit>().search(q),
      onChanged: (q) {
        if (q.isEmpty) context.read<ChatListCubit>().clearSearch();
        setState(() {});
      },
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search messages',
        hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
        prefixIcon: Icon(Icons.search, size: 16, color: c.textMuted),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 32, minHeight: 32),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                icon: Icon(Icons.close, size: 14, color: c.textMuted),
                tooltip: 'Clear search',
                onPressed: () {
                  _search.clear();
                  context.read<ChatListCubit>().clearSearch();
                  setState(() {});
                },
              ),
        filled: true,
        fillColor: c.surfacePanel,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.separator),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.separator),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfaceBase,
      child: Column(
        children: [
          if (widget.accounts.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: widget.accountId,
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: c.surfacePanel,
                  style: TextStyle(fontSize: 13, color: c.textPrimary),
                  items: [
                    for (final a in widget.accounts)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text(a.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null && id != widget.accountId) {
                      _search.clear();
                      widget.onAccountChanged(id);
                    }
                  },
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 4, 6),
            child: Row(
              children: [
                Expanded(child: _searchField(context)),
                BlocSelector<ChatListCubit, ChatListState, bool>(
                  selector: (s) => s.sortByName,
                  builder: (context, byName) => PopupMenuButton<bool>(
                    tooltip: byName ? 'Sorted by name' : 'Sorted by most recent',
                    icon: Icon(
                        byName
                            ? Icons.sort_by_alpha_rounded
                            : Icons.schedule_rounded,
                        size: 17,
                        color: c.textMuted),
                    initialValue: byName,
                    onSelected: context.read<ChatListCubit>().setSortByName,
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: false, child: Text('Most recent first')),
                      PopupMenuItem(value: true, child: Text('Name')),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: BlocBuilder<ChatListCubit, ChatListState>(
              builder: (context, state) {
                if (state.access == ChatAccess.needsConsent) {
                  return const SizedBox.shrink();
                }
                if (state.loading && state.conversations.isEmpty) {
                  return const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.accent),
                    ),
                  );
                }
                if (state.searching || state.results != null) {
                  return _SearchResults(state: state, onOpen: widget.onOpen);
                }
                return _Grouped(
                  state: state,
                  collapsed: _collapsed,
                  onToggle: (team) => setState(() {
                    if (!_collapsed.remove(team)) _collapsed.add(team);
                  }),
                  onOpen: widget.onOpen,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Grouped extends StatelessWidget {
  const _Grouped({
    required this.state,
    required this.collapsed,
    required this.onToggle,
    required this.onOpen,
  });

  final ChatListState state;
  final Set<String> collapsed;
  final ValueChanged<String> onToggle;
  final ValueChanged<ChatConversation> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chats = state.chats;
    final spaces = state.spaces;
    final teams = state.teams;
    return RefreshIndicator(
      onRefresh: context.read<ChatListCubit>().refresh,
      child: ListView(
        children: [
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(state.error!,
                  style: TextStyle(fontSize: 12, color: c.errorBannerText)),
            ),
          _SectionHeader(label: 'Chats'),
          if (chats.isEmpty && state.error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text('No chats yet.',
                  style: TextStyle(fontSize: 12, color: c.textMuted)),
            ),
          for (final chat in chats)
            _ConversationRow(
              conversation: chat,
              selected: chat.key == state.selectedKey,
              onTap: () => onOpen(chat),
            ),
          if (spaces.isNotEmpty)
            _SectionHeader(
                label: ChatSource.isSlackId(state.accountId)
                    ? 'Channels'
                    : 'Spaces'),
          for (final space in spaces)
            _ConversationRow(
              conversation: space,
              selected: space.key == state.selectedKey,
              onTap: () => onOpen(space),
            ),
          if (teams.isNotEmpty) _SectionHeader(label: 'Teams'),
          for (final (name, channels) in teams) ...[
            InkWell(
              onTap: () => onToggle(channels.first.teamId!),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                child: Row(
                  children: [
                    Icon(
                      collapsed.contains(channels.first.teamId)
                          ? Icons.chevron_right
                          : Icons.expand_more,
                      size: 16,
                      color: c.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.groups_2_outlined,
                        size: 15, color: c.textTertiary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: c.textSecondary)),
                    ),
                  ],
                ),
              ),
            ),
            if (!collapsed.contains(channels.first.teamId))
              for (final ch in channels)
                _ConversationRow(
                  conversation: ch,
                  selected: ch.key == state.selectedKey,
                  indent: true,
                  onTap: () => onOpen(ch),
                ),
          ],
          if (state.access == ChatAccess.chatsOnly)
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextButton.icon(
                icon: const Icon(Icons.groups_2_outlined, size: 16),
                label: const Text('Show team channels'),
                onPressed: () => context
                    .read<ChatListCubit>()
                    .requestAccess(channels: true),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w700,
          color: c.textMuted,
        ),
      ),
    );
  }
}

String _when(DateTime? at) {
  if (at == null) return '';
  final now = DateTime.now();
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return DateFormat.jm().format(at);
  }
  if (now.difference(at).inDays < 7) return DateFormat.E().format(at);
  return DateFormat(at.year == now.year ? 'd MMM' : 'd/M/yy').format(at);
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
    this.indent = false,
  });

  final ChatConversation conversation;
  final bool selected;
  final bool indent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final icon = switch (conversation.kind) {
      ChatKind.oneOnOne => Icons.person_outline,
      ChatKind.group => Icons.people_outline,
      ChatKind.meeting => Icons.event_outlined,
      ChatKind.channel => Icons.tag,
      ChatKind.space => Icons.workspaces_outline,
    };
    final unread = conversation.unread && !selected;
    return Material(
      color: selected ? c.selectionBg : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(indent ? 30 : 12, 7, 12, 7),
          child: Row(
            children: [
              Icon(icon, size: 16, color: c.textTertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              // Bold is "unread", as in the mail list.
                              fontWeight: unread
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: c.textPrimary,
                            ),
                          ),
                        ),
                        if (unread) ...[
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: AppColors.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(_when(conversation.lastActivity),
                            style: TextStyle(
                                fontSize: 11,
                                color: unread ? c.textPrimary : c.textMuted,
                                fontWeight: unread
                                    ? FontWeight.w600
                                    : FontWeight.w400)),
                      ],
                    ),
                    if ((conversation.lastMessagePreview ?? '').isNotEmpty)
                      Text(
                        conversation.lastMessagePreview!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.textTertiary),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.state, required this.onOpen});

  final ChatListState state;
  final ValueChanged<ChatConversation> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (state.searching) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
        ),
      );
    }
    final hits = state.results ?? const [];
    if (hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          state.error ?? 'Nothing found for "${state.query}".',
          style: TextStyle(fontSize: 12.5, color: c.textTertiary),
        ),
      );
    }
    final byKey = {for (final x in state.conversations) x.key: x};
    return ListView.separated(
      itemCount: hits.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: c.separator),
      itemBuilder: (context, i) {
        final hit = hits[i];
        final m = hit.message;
        final known = byKey[hit.conversationKey];
        final conversation = known ??
            (hit.chatId != null
                ? ChatConversation(
                    id: hit.chatId!,
                    kind: ChatKind.group,
                    title: m.conversationTitle ?? m.senderName,
                  )
                : hit.teamId != null && hit.channelId != null
                    ? ChatConversation(
                        id: hit.channelId!,
                        kind: ChatKind.channel,
                        teamId: hit.teamId,
                        title: m.conversationTitle ?? 'Channel',
                      )
                    : null);
        return InkWell(
          onTap: conversation == null ? null : () => onOpen(conversation),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        known?.title ?? m.conversationTitle ?? m.senderName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary),
                      ),
                    ),
                    Text(_when(m.createdAt),
                        style: TextStyle(fontSize: 11, color: c.textMuted)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${m.senderName.isEmpty ? '' : '${m.senderName}: '}'
                  '${htmlToPlainText(m.bodyHtml).replaceAll(RegExp(r'\s+'), ' ')}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: c.textTertiary),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({required this.google, this.slackWorkspace});

  final bool google;

  /// The Slack workspace shown, by name; null for an account's own chat.
  final String? slackWorkspace;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<ChatConversationCubit, ChatConversationState>(
      builder: (context, state) {
        if (state.access == ChatAccess.needsConsent) {
          return ChatConsentPrompt(
            google: google,
            slackWorkspace: slackWorkspace,
            error: state.error,
            onGrant: () async {
              final accountId = state.accountId;
              if (accountId == null) return;
              final access = await context
                  .read<ChatConversationCubit>()
                  .requestAccess(accountId);
              if (access != null && context.mounted) {
                unawaited(context.read<ChatListCubit>().load(accountId));
              }
            },
          );
        }
        final conversation = state.conversation;
        if (conversation == null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.forum_outlined, size: 40, color: c.stateIcon),
                const SizedBox(height: 8),
                Text('Select a chat or channel',
                    style: TextStyle(fontSize: 13, color: c.textTertiary)),
              ],
            ),
          );
        }
        return Column(
          children: [
            SizedBox(
              height: touchRowHeight(48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(
                      conversation.isChannel ? Icons.tag : Icons.forum_outlined,
                      size: 16,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        conversation.isChannel && conversation.teamName != null
                            ? '${conversation.teamName} › ${conversation.title}'
                            : conversation.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                    if (conversation.members.length > 1)
                      Tooltip(
                        message: conversation.members
                            .map((m) => m.displayName)
                            .join('\n'),
                        child: Row(
                          children: [
                            Icon(Icons.people_outline,
                                size: 15, color: c.textMuted),
                            const SizedBox(width: 3),
                            Text('${conversation.members.length + 1}',
                                style: TextStyle(
                                    fontSize: 12, color: c.textMuted)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: c.separatorStrong),
            const Expanded(child: ChatConversationView(wideThreads: true)),
          ],
        );
      },
    );
  }
}
