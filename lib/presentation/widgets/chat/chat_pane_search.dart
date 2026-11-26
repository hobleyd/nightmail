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
import 'chat_conversation_row.dart';

/// Chats and channels whose name, team or members contain [q] (lower case):
/// names that start with it first, each group in [list]'s order.
List<ChatConversation> matchChats(
    Iterable<ChatConversation> list, String q, {int? limit}) {
  bool has(String? text) => text != null && text.toLowerCase().contains(q);
  final hits = [
    for (final ch in list)
      if (has(ch.title) ||
          has(ch.teamName) ||
          ch.members.any((m) => has(m.displayName) || has(m.email)))
        ch,
  ];
  bool starts(ChatConversation ch) {
    final t = ch.title.toLowerCase();
    return t.startsWith(q) || t.startsWith('#$q');
  }

  final sorted = [...hits.where(starts), ...hits.where((ch) => !starts(ch))];
  return limit == null ? sorted : sorted.take(limit).toList();
}

/// The top of the Chat pane: the chosen system's unread chats and channels,
/// newest first, with a field at its foot (just above the divider) that
/// finds anyone or any chat or channel by name. The results take the list's
/// place until the field is cleared; the open chat stays listed,
/// highlighted, once it is read.
///
/// - **People:** the email's [people] (already narrowed to those a chat can
///   exist with), then the local contacts typeahead ([SearchContacts]:
///   indexed SQL, never the network), offered only when
///   [ChatRepository.reachable] says a chat with them can exist — asked once
///   per name for as long as the list lives, since on Google each outsider
///   is a request.
/// - **Chats and channels:** [matchChats] over every listed conversation —
///   the cache on disk at once, then one [ChatRepository.conversations], on
///   the first keystroke, never just for being shown. Someone with a
///   matching one-on-one is offered as that chat, not as a person.
class ChatPaneList extends StatefulWidget {
  const ChatPaneList({
    super.key,
    required this.chatId,
    required this.account,
    required this.people,
    required this.chats,
    required this.selected,
    required this.onChat,
    required this.onPerson,
  });

  /// The chat system: an account id or `slack:{team}`.
  final String chatId;

  /// The mail account whose address book the field searches.
  final Account account;

  /// The email's people the pane can chat with.
  final List<ChatPerson> people;

  /// The system's unread chats, and a held one.
  final List<ChatConversation> chats;
  final ChatConversation? selected;
  final ValueChanged<ChatConversation> onChat;
  final ValueChanged<ChatPerson> onPerson;

  @override
  State<ChatPaneList> createState() => _ChatPaneListState();
}

class _ChatPaneListState extends State<ChatPaneList> {
  static const _debounce = Duration(milliseconds: 200);

  final _query = TextEditingController();
  final _focus = FocusNode();
  List<ChatConversation> _all = const [];
  bool _loading = false;
  bool _loaded = false;
  Timer? _timer;

  /// People the address book found for [_foundFor], already filtered to
  /// those a chat can exist with.
  List<ChatPerson> _found = const [];
  String _foundFor = '';
  int _searchId = 0;

  /// [ChatRepository.reachable]'s answers, per address.
  final _reachable = <String, bool>{};

  /// On the selected row, so a pick that lands below (or above) the rows in
  /// view — an older chat from search — is scrolled to.
  final _selectedRow = GlobalKey();

  @override
  void didUpdateWidget(ChatPaneList old) {
    super.didUpdateWidget(old);
    if (widget.selected != null && widget.selected?.key != old.selected?.key) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  /// Scrolls the selected row just into view; a no-op when it already is.
  Future<void> _reveal() async {
    final row = _selectedRow.currentContext;
    if (row == null || !mounted) return;
    const d = Duration(milliseconds: 200);
    await Scrollable.ensureVisible(row,
        duration: d,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    final again = _selectedRow.currentContext;
    if (again == null || !mounted) return;
    await Scrollable.ensureVisible(again,
        duration: d,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    setState(() => _loading = true);
    final repo = sl<ChatRepository>();
    final cached = await repo.cachedConversations(widget.chatId);
    if (!mounted) return;
    if (cached.isNotEmpty) setState(() => _all = cached);
    final listed = await repo.conversations(widget.chatId);
    if (!mounted) return;
    listed.match(
      (f) => debugPrint('[Chat] pane search: list unavailable: $f'),
      (l) => _all = l,
    );
    setState(() => _loading = false);
  }

  void _onChanged(String text) {
    _timer?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      _searchId++;
      _found = const [];
      _foundFor = '';
    } else {
      unawaited(_load());
      _timer = Timer(_debounce, () => _searchPeople(q));
    }
    setState(() {});
  }

  Future<void> _searchPeople(String q) async {
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
      debugPrint('[Chat] pane search: people search failed: $e');
      if (mounted && id == _searchId) {
        setState(() {
          _found = const [];
          _foundFor = q;
        });
      }
    }
  }

  void _clear() {
    _timer?.cancel();
    _searchId++;
    _query.clear();
    _found = const [];
    _foundFor = '';
    setState(() {});
  }

  void _openChat(ChatConversation chat) {
    widget.onChat(chat);
    _clear();
    _focus.unfocus();
  }

  void _openPerson(ChatPerson person) {
    widget.onPerson(person);
    _clear();
    _focus.unfocus();
  }

  Widget _personRow(ChatPerson p) => _PersonRow(
      key: ValueKey('person:${p.email}'),
      person: p,
      onTap: () => _openPerson(p));

  static bool _matches(String? text, String q) =>
      text != null && text.toLowerCase().contains(q);

  /// What [q] finds, in the order shown: the email's people, then chats
  /// and channels, then the address book's people — last, because they
  /// land after a debounce and [ChatRepository.reachable], and must not push
  /// rows already shown out from under the pointer. Someone with a listed
  /// one-on-one that matches is offered as that chat, not as a person: the
  /// chat holds the pane across emails, a person does not.
  ({
    List<ChatPerson> onEmail,
    List<ChatConversation> chats,
    List<ChatPerson> found,
  }) _results(String q) {
    final chats = _chatsFor(q);
    final seen = <String>{
      for (final ch in chats)
        if (ch.kind == ChatKind.oneOnOne)
          for (final m in ch.members)
            if (m.email != null) m.email!,
    };
    bool matches(ChatPerson p) =>
        (_matches(p.name, q) || _matches(p.email, q)) && seen.add(p.email);
    return (
      onEmail: [for (final p in widget.people) if (matches(p)) p],
      chats: chats,
      // A late answer for an older query still narrows to this one.
      found: [
        if (_foundFor.isNotEmpty)
          for (final p in _found) if (matches(p)) p,
      ],
    );
  }

  /// Chats and channels matching [q], newest first within each group,
  /// unread ones bold as the poll says (full listings carry no read state
  /// on Slack or Google).
  List<ChatConversation> _chatsFor(String q) {
    final unread = {for (final u in widget.chats) if (u.unread) u.key};
    final byActivity = [..._all]..sort((a, b) {
        final at = a.lastActivity, bt = b.lastActivity;
        if (at == null || bt == null) {
          return at == null ? (bt == null ? 0 : 1) : -1;
        }
        return bt.compareTo(at);
      });
    return [
      for (final ch in matchChats(byActivity, q, limit: 50))
        unread.contains(ch.key) ? ch.copyWith(unread: true) : ch,
    ];
  }

  /// Enter: the first row shown.
  void _submit(String q) {
    if (q.isEmpty) return;
    final r = _results(q);
    if (r.onEmail.isNotEmpty) return _openPerson(r.onEmail.first);
    if (r.chats.isNotEmpty) return _openChat(r.chats.first);
    if (r.found.isNotEmpty) _openPerson(r.found.first);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final q = _query.text.trim().toLowerCase();
    final searching = q.isNotEmpty;
    final r = searching ? _results(q) : null;
    final onEmail = r?.onEmail ?? const <ChatPerson>[];
    final found = r?.found ?? const <ChatPerson>[];
    final shown = r?.chats ?? widget.chats;
    final pending = _loading || _foundFor != _query.text.trim();

    final Widget list;
    if (shown.isEmpty && onEmail.isEmpty && found.isEmpty) {
      list = Center(
        child: Text(
          !searching
              ? 'No unread chats'
              : pending
                  ? 'Searching…'
                  : 'No one or nothing matches',
          style: TextStyle(fontSize: 12.5, color: c.textTertiary),
        ),
      );
    } else {
      // Every row built (unread, or at most 50 matches), so the selected
      // one has a context to scroll to wherever it sits.
      list = SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final p in onEmail) _personRow(p),
            for (final ch in shown)
              ChatConversationRow(
                key: !searching && ch.key == widget.selected?.key
                    ? _selectedRow
                    : ValueKey(ch.key),
                conversation: ch,
                selected: ch.key == widget.selected?.key,
                onTap: () => _openChat(ch),
              ),
            for (final p in found) _personRow(p),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(child: list),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () {
                _clear();
                _focus.unfocus();
              },
            },
            child: TextField(
              controller: _query,
              focusNode: _focus,
              onChanged: _onChanged,
              onSubmitted: (_) => _submit(q),
              style: TextStyle(fontSize: 13, color: c.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Find a person, chat or channel',
                hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
                prefixIcon: Icon(Icons.search, size: 16, color: c.textMuted),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 30, minHeight: 28),
                suffixIcon: searching
                    ? IconButton(
                        icon: Icon(Icons.close, size: 14, color: c.textMuted),
                        tooltip: 'Clear',
                        onPressed: _clear,
                      )
                    : null,
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                contentPadding: const EdgeInsets.symmetric(vertical: 7),
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
      ],
    );
  }
}

/// A person found by the pane's search: name, and the address under it.
class _PersonRow extends StatelessWidget {
  const _PersonRow({super.key, required this.person, required this.onTap});

  final ChatPerson person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Row(
            children: [
              Icon(Icons.person_outline, size: 16, color: c.textTertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(person.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: c.textPrimary)),
                    if (person.name.isNotEmpty)
                      Text(person.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(fontSize: 12, color: c.textTertiary)),
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
