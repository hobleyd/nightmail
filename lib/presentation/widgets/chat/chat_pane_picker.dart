import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/chat.dart';
import '../../../domain/repositories/chat_repository.dart';
import '../../../domain/usecases/search_contacts.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../injection_container.dart';
import '../../blocs/chat/chat_conversation_cubit.dart';

/// The Chat pane's header: who or what the pane shows, and a menu to pick
/// another — the email's people and the system's unread chats, under a field
/// that finds anyone or any chat or channel by name.
///
/// People found by the field come from the local contacts typeahead
/// ([SearchContacts]: indexed SQL, never the network) and are offered only
/// when [ChatRepository.reachable] says a chat with them can exist — the
/// same rule as the email's people. Chats and channels are matched in the
/// listed conversations, painted from the cache on disk while the listing
/// is asked once per menu.
class ChatPanePicker extends StatefulWidget {
  const ChatPanePicker({
    super.key,
    required this.chatId,
    required this.account,
    required this.people,
    required this.chats,
    required this.selectedPerson,
    required this.selectedChat,
    required this.onPerson,
    required this.onChat,
  });

  /// The chat system: an account id or `slack:{team}`.
  final String chatId;

  /// The mail account whose address book the field searches.
  final Account account;

  /// The email's people the pane can chat with.
  final List<ChatPerson> people;

  /// The system's unread chats.
  final List<ChatConversation> chats;

  final ChatPerson? selectedPerson;
  final ChatConversation? selectedChat;
  final ValueChanged<ChatPerson> onPerson;
  final ValueChanged<ChatConversation> onChat;

  @override
  State<ChatPanePicker> createState() => _ChatPanePickerState();
}

class _ChatPanePickerState extends State<ChatPanePicker> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = widget.selectedChat?.title ??
        widget.selectedPerson?.label ??
        (widget.chats.isNotEmpty ? '${widget.chats.length} unread' : 'Chat');
    final placeholder =
        widget.selectedChat == null && widget.selectedPerson == null;
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 4),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surfacePanel),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      menuChildren: [
        _PickerContent(
          key: ValueKey(widget.chatId),
          chatId: widget.chatId,
          account: widget.account,
          people: widget.people,
          chats: widget.chats,
          selectedPerson: widget.selectedPerson,
          selectedChat: widget.selectedChat,
          onPerson: (p) {
            _menu.close();
            widget.onPerson(p);
          },
          onChat: (ch) {
            _menu.close();
            widget.onChat(ch);
          },
        ),
      ],
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Row(
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: placeholder ? c.textSecondary : c.textPrimary,
                  fontSize: 14,
                  fontWeight: placeholder ? FontWeight.w400 : FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 20, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

class _PickerContent extends StatefulWidget {
  const _PickerContent({
    super.key,
    required this.chatId,
    required this.account,
    required this.people,
    required this.chats,
    required this.selectedPerson,
    required this.selectedChat,
    required this.onPerson,
    required this.onChat,
  });

  final String chatId;
  final Account account;
  final List<ChatPerson> people;
  final List<ChatConversation> chats;
  final ChatPerson? selectedPerson;
  final ChatConversation? selectedChat;
  final ValueChanged<ChatPerson> onPerson;
  final ValueChanged<ChatConversation> onChat;

  @override
  State<_PickerContent> createState() => _PickerContentState();
}

class _PickerContentState extends State<_PickerContent> {
  static const _debounce = Duration(milliseconds: 200);
  static const _maxChats = 12;

  final _query = TextEditingController();
  Timer? _timer;

  /// Every chat and channel of the system, once listed.
  List<ChatConversation> _list = const [];

  /// People the address book found for [_foundFor], already filtered to
  /// those a chat can exist with.
  List<ChatPerson> _found = const [];
  String _foundFor = '';
  int _searchId = 0;

  /// [ChatRepository.reachable]'s answers while the menu is open: on Google
  /// each outsider is a request, so a name is asked once per menu, not once
  /// per keystroke.
  final _reachable = <String, bool>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadList());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadList() async {
    final repo = sl<ChatRepository>();
    final cached = await repo.cachedConversations(widget.chatId);
    if (!mounted) return;
    if (cached.isNotEmpty) setState(() => _list = cached);
    final listed = await repo.conversations(widget.chatId);
    if (!mounted) return;
    listed.match(
      (f) => debugPrint('[Chat] pane picker: list unavailable: $f'),
      (l) => setState(() => _list = l),
    );
  }

  void _onChanged(String text) {
    setState(() {});
    _timer?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      _searchId++;
      setState(() {
        _found = const [];
        _foundFor = '';
      });
      return;
    }
    _timer = Timer(_debounce, () => _search(q));
  }

  Future<void> _search(String q) async {
    final id = ++_searchId;
    final own = widget.account.allAddresses;
    try {
      final suggestions = await sl<SearchContacts>().call(
        query: q,
        accountId: widget.account.id,
        accountDomain: widget.account.emailAddress.split('@').lastOrNull,
      );
      final seen = <String>{};
      final people = [
        for (final s in suggestions)
          if (s.address.trim().isNotEmpty &&
              !own.contains(s.address.trim().toLowerCase()) &&
              seen.add(s.address.trim().toLowerCase()))
            ChatPerson(
              email: s.address.trim().toLowerCase(),
              name: (s.name ?? '').trim(),
            ),
      ];
      final unknown = [
        for (final p in people)
          if (!_reachable.containsKey(p.email)) (email: p.email, name: p.name),
      ];
      if (unknown.isNotEmpty) {
        final ok = await sl<ChatRepository>().reachable(widget.chatId, unknown);
        for (final p in unknown) {
          _reachable[p.email] = ok.contains(p.email);
        }
      }
      if (!mounted || id != _searchId) return;
      setState(() {
        _found = [
          for (final p in people)
            if (_reachable[p.email] ?? false) p,
        ];
        _foundFor = q;
      });
    } catch (e) {
      debugPrint('[Chat] pane picker: people search failed: $e');
      if (mounted && id == _searchId) {
        setState(() {
          _found = const [];
          _foundFor = q;
        });
      }
    }
  }

  static bool _matches(String? text, String q) =>
      text != null && text.toLowerCase().contains(q);

  /// The email's people, then the address book's, matching [q].
  List<ChatPerson> _peopleFor(String q) {
    final seen = <String>{};
    return [
      for (final p in widget.people)
        if ((_matches(p.name, q) || _matches(p.email, q)) && seen.add(p.email))
          p,
      // A late answer for an older query still narrows to this one.
      if (_foundFor.isNotEmpty)
        for (final p in _found)
          if ((_matches(p.name, q) || _matches(p.email, q)) &&
              seen.add(p.email))
            p,
    ];
  }

  /// Chats and channels whose name, team or members match [q]: names that
  /// start with it first, then by activity. A one-on-one with someone
  /// already offered as a person is left out.
  List<ChatConversation> _chatsFor(String q, Set<String> people) {
    final hits = [
      for (final ch in _list)
        if ((_matches(ch.title, q) ||
                _matches(ch.teamName, q) ||
                ch.members.any((m) =>
                    _matches(m.displayName, q) || _matches(m.email, q))) &&
            !(ch.kind == ChatKind.oneOnOne &&
                ch.members.any((m) => people.contains(m.email))))
          ch,
    ];
    bool starts(ChatConversation ch) {
      final t = ch.title.toLowerCase();
      return t.startsWith(q) || t.startsWith('#$q');
    }

    return [
      ...hits.where(starts),
      ...hits.where((ch) => !starts(ch)),
    ].take(_maxChats).toList();
  }

  void _submit() {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return;
    final people = _peopleFor(q);
    if (people.isNotEmpty) return widget.onPerson(people.first);
    final chats = _chatsFor(q, const {});
    if (chats.isNotEmpty) widget.onChat(chats.first);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final q = _query.text.trim().toLowerCase();
    final List<ChatPerson> people;
    final List<ChatConversation> chats;
    if (q.isEmpty) {
      people = widget.people;
      chats = widget.chats;
    } else {
      people = _peopleFor(q);
      chats = _chatsFor(q, {for (final p in people) p.email});
    }
    final searching = q.isNotEmpty && _foundFor != _query.text.trim();

    return SizedBox(
      width: 300,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            // The menu takes the arrow keys for moving between items; left
            // and right go back to the field, to move its cursor.
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.arrowLeft):
                    ExtendSelectionByCharacterIntent(
                        forward: false, collapseSelection: true),
                SingleActivator(LogicalKeyboardKey.arrowRight):
                    ExtendSelectionByCharacterIntent(
                        forward: true, collapseSelection: true),
              },
              child: TextField(
                controller: _query,
                autofocus: true,
                onChanged: _onChanged,
                onSubmitted: (_) => _submit(),
                style: TextStyle(fontSize: 13, color: c.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Find a person or channel',
                  hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
                  prefixIcon:
                      Icon(Icons.search, size: 16, color: c.textMuted),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.separatorStrong),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.separatorStrong),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            // The menu's own panel scrolls too: this list must not take
            // the primary controller from it.
            child: SingleChildScrollView(
              primary: false,
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (q.isNotEmpty && people.isNotEmpty)
                    _Heading('PEOPLE', color: c.textMuted),
                  for (final p in people)
                    _Item(
                      icon: Icons.person_outline,
                      title: p.label,
                      subtitle: p.name.isNotEmpty ? p.email : null,
                      selected: widget.selectedChat == null &&
                          widget.selectedPerson?.email == p.email,
                      onTap: () => widget.onPerson(p),
                    ),
                  if (chats.isNotEmpty)
                    _Heading(q.isEmpty ? 'UNREAD' : 'CHATS AND CHANNELS',
                        color: c.textMuted),
                  for (final ch in chats)
                    _Item(
                      icon: switch (ch.kind) {
                        ChatKind.oneOnOne => Icons.person_outline,
                        ChatKind.channel || ChatKind.space => Icons.tag,
                        _ => Icons.people_outline,
                      },
                      title: ch.title,
                      subtitle: ch.isChannel ? ch.teamName : null,
                      unread: ch.unread,
                      selected: widget.selectedChat?.key == ch.key,
                      onTap: () => widget.onChat(ch),
                    ),
                  if (people.isEmpty && chats.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      child: Text(
                        q.isEmpty
                            ? 'Type a name to find a person or channel.'
                            : searching
                                ? 'Searching…'
                                : 'No one or nothing matches.',
                        style:
                            TextStyle(fontSize: 12.5, color: c.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 10.5,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      );
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.unread = false,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool unread;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MenuItemButton(
      onPressed: onTap,
      // Hovering a result must not take the typing away from the field.
      requestFocusOnHover: false,
      leadingIcon: Icon(icon, size: 15, color: c.textTertiary),
      trailingIcon: unread
          ? Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
            )
          : selected
              ? const Icon(Icons.check, size: 15, color: AppColors.accent)
              : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                color: c.textPrimary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(
                subtitle!,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: c.textTertiary),
              ),
          ],
        ),
      ),
    );
  }
}
