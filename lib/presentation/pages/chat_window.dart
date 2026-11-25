import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
import '../widgets/chat/chat_window_target.dart';
import '../widgets/chat/chat_conversation_row.dart';
import '../widgets/chat/chat_conversation_view.dart';
import '../widgets/chat/chat_read_relay.dart';
import '../widgets/chat/chat_rename_dialog.dart';

/// The chat window, opened by double-clicking the Chat button: every chat
/// and channel on the left, grouped and newest first, the open one's history
/// on the right, search across them all.
///
/// It opens on the active account's own chat (Teams, Google Chat, NightMail
/// Server); connected Slack workspaces are further entries in its picker,
/// and the one it opens on when the account has no chat of its own.
/// Opened from the Chat pane it starts on the pane's system and
/// conversation instead ([initial]); an open window is pointed there too.
class ChatWindowApp extends StatelessWidget {
  const ChatWindowApp({super.key, this.initial});

  final ChatWindowTarget? initial;

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
            home: _ChatWindowPage(initial: initial),
          );
        },
      ),
    );
  }
}

class _ChatWindowPage extends StatefulWidget {
  const _ChatWindowPage({this.initial});

  final ChatWindowTarget? initial;

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

  /// Where the Chat pane asked this window to go, until its system is in
  /// the picker — a Slack workspace only once the Keychain has been read.
  late ChatWindowTarget? _target = widget.initial;

  @override
  void initState() {
    super.initState();
    final repo = sl<ChatRepository>();
    _slackChanges = repo.sourcesChanged.listen((_) => _loadSlack());
    _loadSlack();
    ChatReadRelay.start(repo);
    unawaited(_listenForTargets());
  }

  /// The Chat pane points a window that is already open with
  /// [ChatWindowTarget.openMethod].
  Future<void> _listenForTargets() async {
    try {
      final controller = await WindowController.fromCurrentEngine();
      await controller.setWindowMethodHandler((MethodCall call) async {
        if (ChatReadRelay.handle(call, sl<ChatRepository>())) return null;
        if (call.method == ChatWindowTarget.openMethod && mounted) {
          final target = ChatWindowTarget.fromJson(call.arguments);
          if (target != null) {
            _target = target;
            _ensureAccount(context.read<AccountCubit>().state);
          }
        }
        return null;
      });
    } catch (e) {
      debugPrint('[Chat] window handler failed: $e');
    }
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
    if (_goToTarget(s)) return;
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

  /// Goes to [_target] once its system is offered; true while it is
  /// pending, so the default choice does not win the race. A system no
  /// longer offered (a workspace disconnected) falls back to the default.
  bool _goToTarget(AccountState s) {
    final target = _target;
    if (target == null) return false;
    if (!_entries(s).any((e) => e.id == target.sourceId)) {
      if (s is! AccountsLoaded || _slack == null) return true;
      _target = null;
      return false;
    }
    _target = null;
    if (_accountId != target.sourceId) {
      setState(() => _switchTo(target.sourceId));
    }
    if (target.conversation case final c?) {
      unawaited(_openTarget(target.sourceId, c));
    }
    return true;
  }

  /// [c] as this window's list knows it — with its members — when it does.
  Future<void> _openTarget(String sourceId, ChatConversation c) async {
    final known = await sl<ChatRepository>().cachedConversations(sourceId);
    if (!mounted || _accountId != sourceId) return;
    _open(known.where((k) => k.key == c.key).firstOrNull ?? c);
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

  /// Sections ('chats', 'spaces', 'teams') showing their quiet conversations.
  final _showQuiet = <String>{};

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
                  showQuiet: _showQuiet,
                  onToggleQuiet: (section) => setState(() {
                    if (!_showQuiet.remove(section)) _showQuiet.add(section);
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
    required this.showQuiet,
    required this.onToggleQuiet,
    required this.onOpen,
  });

  final ChatListState state;
  final Set<String> collapsed;
  final ValueChanged<String> onToggle;
  final Set<String> showQuiet;
  final ValueChanged<String> onToggleQuiet;
  final ValueChanged<ChatConversation> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Conversations with nothing new in a week wait under each section's
    // "older" row, in the section's own order, until it is opened.
    final now = DateTime.now();
    bool quiet(ChatConversation x) => state.isQuiet(x, now);
    final allChats = state.chats;
    final chats = allChats.where((x) => !quiet(x)).toList();
    final quietChats = allChats.where(quiet).toList();
    final allSpaces = state.spaces;
    final spaces = allSpaces.where((x) => !quiet(x)).toList();
    final quietSpaces = allSpaces.where(quiet).toList();
    final channels = state.conversations.where((x) => x.isChannel);
    final teams = state.teamsOf(channels.where((x) => !quiet(x)));
    final quietChannels = channels.where(quiet).toList();
    final quietTeams = state.teamsOf(quietChannels);

    Widget row(ChatConversation x, {bool indent = false}) => ChatConversationRow(
          conversation: x,
          selected: x.key == state.selectedKey,
          indent: indent,
          onTap: () => onOpen(x),
        );

    List<Widget> team(String name, List<ChatConversation> channels) => [
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
            for (final ch in channels) row(ch, indent: true),
        ];

    Widget older(String section, int count) => _QuietToggle(
          count: count,
          open: showQuiet.contains(section),
          onTap: () => onToggleQuiet(section),
        );
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
          if (allChats.isEmpty && state.error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text('No chats yet.',
                  style: TextStyle(fontSize: 12, color: c.textMuted)),
            ),
          for (final chat in chats) row(chat),
          if (quietChats.isNotEmpty) ...[
            older('chats', quietChats.length),
            if (showQuiet.contains('chats'))
              for (final chat in quietChats) row(chat),
          ],
          if (allSpaces.isNotEmpty)
            _SectionHeader(
                label: ChatSource.isSlackId(state.accountId)
                    ? 'Channels'
                    : 'Spaces'),
          for (final space in spaces) row(space),
          if (quietSpaces.isNotEmpty) ...[
            older('spaces', quietSpaces.length),
            if (showQuiet.contains('spaces'))
              for (final space in quietSpaces) row(space),
          ],
          if (teams.isNotEmpty || quietTeams.isNotEmpty)
            _SectionHeader(label: 'Teams'),
          for (final (name, channels) in teams) ...team(name, channels),
          if (quietChannels.isNotEmpty) ...[
            older('teams', quietChannels.length),
            if (showQuiet.contains('teams'))
              for (final (name, channels) in quietTeams)
                ...team(name, channels),
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

/// The row at the foot of a section that shows or hides its conversations
/// with nothing new in [ChatListState.quietAfter].
class _QuietToggle extends StatelessWidget {
  const _QuietToggle({
    required this.count,
    required this.open,
    required this.onTap,
  });

  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Row(
          children: [
            Icon(open ? Icons.expand_less : Icons.expand_more,
                size: 16, color: c.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                open ? 'Hide older' : 'Show $count older',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
            ),
          ],
        ),
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
                    Text(chatWhen(m.createdAt),
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

  /// Renames [conversation]; its row on the left follows at once.
  Future<void> _rename(
      BuildContext context, ChatConversation conversation) async {
    final cubit = context.read<ChatConversationCubit>();
    final list = context.read<ChatListCubit>();
    final renamed = await showChatRenameDialog(context,
        conversation: conversation, rename: cubit.rename);
    final now = cubit.state.conversation;
    if (renamed && now != null && now.key == conversation.key) {
      list.renamed(now);
    }
  }

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
                    if (context.read<ChatConversationCubit>().canRename)
                      IconButton(
                        icon: Icon(Icons.edit_outlined,
                            size: 15, color: c.textMuted),
                        tooltip: 'Rename',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _rename(context, conversation),
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
