import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/platform/touch_metrics.dart';
import '../../../core/platform/window_utils.dart';
import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/repositories/chat_repository.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../injection_container.dart';
import '../../blocs/account/account_cubit.dart';
import '../../blocs/chat/chat_conversation_cubit.dart';
import '../../blocs/email_detail/email_detail_bloc.dart';
import '../../blocs/email_detail/email_detail_state.dart';
import 'chat_conversation_view.dart';

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

  Future<void> _sync(String accountId, ChatPerson? person) async {
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
    final key = person == null ? null : '$accountId|${person.email}';
    if (key == _openedKey) return;
    _openedKey = key;
    if (person == null) {
      cubit.clear();
    } else {
      unawaited(cubit.openPerson(accountId, person));
    }
  }

  Future<void> _grant() async {
    final accountId = _accountId;
    if (accountId == null) return;
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
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accountState = context.watch<AccountCubit>().state;
    final account =
        accountState is AccountsLoaded ? accountState.activeAccount : null;
    final detail = context.watch<EmailDetailBloc>().state;
    final email = detail is EmailDetailLoaded ? detail.email : null;

    final everyone =
        account == null ? const <ChatPerson>[] : candidatesFor(email, account);
    if (account != null) {
      final key = '${account.id}|${email?.id}';
      if (key != _colleaguesKey) _checkColleagues(account.id, key, everyone);
    }
    final colleagues = _colleagues;
    final candidates = colleagues == null
        ? const <ChatPerson>[]
        : everyone.where((p) => colleagues.contains(p.email)).toList();
    final person = candidates
            .where((p) => p.email == _chosen)
            .firstOrNull ??
        candidates.firstOrNull;

    if (account != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync(account.id, person);
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
                'Google Workspace accounts.',
      );
    } else if (_access == ChatAccess.needsConsent) {
      body = ChatConsentPrompt(
        onGrant: _grant,
        error: _consentError,
        google: account is GmailAccount,
      );
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
              ? 'Select an email to chat with the people on it.'
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
                  Icon(Icons.forum_outlined,
                      size: touchIcon(16), color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: candidates.length > 1
                        ? _PersonDropdown(
                            people: candidates,
                            selected: person!,
                            onChanged: (p) => setState(() => _chosen = p.email),
                          )
                        : Text(
                            person?.label ?? 'Chat',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                  ),
                  if (_isDesktop)
                    IconButton(
                      icon: Icon(Icons.open_in_new_rounded,
                          size: touchIcon(15), color: c.textMuted),
                      tooltip: 'Open chat window',
                      onPressed: () => showOrCreateSubWindow('chat'),
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

class _PersonDropdown extends StatelessWidget {
  const _PersonDropdown({
    required this.people,
    required this.selected,
    required this.onChanged,
  });

  final List<ChatPerson> people;
  final ChatPerson selected;
  final ValueChanged<ChatPerson> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: selected.email,
        isExpanded: true,
        isDense: true,
        dropdownColor: c.surfacePanel,
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        items: [
          for (final p in people)
            DropdownMenuItem(
              value: p.email,
              child: Tooltip(
                message: p.email,
                child: Text(p.label, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
        onChanged: (email) {
          final p = people.where((p) => p.email == email).firstOrNull;
          if (p != null) onChanged(p);
        },
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
