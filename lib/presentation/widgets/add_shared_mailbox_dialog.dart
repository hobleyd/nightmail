import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/contact_suggestion.dart';
import '../../domain/usecases/search_contacts.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';

/// Opened from the folder list's account-name menu. Lets the user add a
/// shared mailbox riding on a Microsoft account's own credentials.
///
/// Graph has no API to list which shared mailboxes a token can reach (see
/// MicrosoftAuthService's `.Shared` scopes), so this searches the parent
/// account's already-synced local directory cache as the user types — the
/// same source and the same "never hit the network per keystroke" rule as
/// [SearchContacts] everywhere else — and only validates a specific address
/// against the server once one is picked
/// ([AccountCubit.resolveSharedMailboxCandidate]).
class AddSharedMailboxDialog extends StatefulWidget {
  const AddSharedMailboxDialog({
    super.key,
    required this.parentAccountId,
    required this.parentAccountLabel,
  });

  /// The real signed-in Microsoft account whose credentials the new shared
  /// mailbox will ride on.
  final String parentAccountId;

  /// Shown in the dialog subtitle so it is clear whose access is being used.
  final String parentAccountLabel;

  @override
  State<AddSharedMailboxDialog> createState() => _AddSharedMailboxDialogState();
}

class _AddSharedMailboxDialogState extends State<AddSharedMailboxDialog> {
  final _queryCtrl = TextEditingController();
  final _queryFocus = FocusNode();
  Timer? _debounce;
  int _searchRequestId = 0;

  List<ContactSuggestion> _suggestions = [];
  bool _isChecking = false;
  String? _error;

  static final _looksLikeEmail = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  @override
  void initState() {
    super.initState();
    _queryFocus.requestFocus();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryCtrl.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _error = null);
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      if (!mounted) return;
      final requestId = ++_searchRequestId;
      try {
        final results = await sl<SearchContacts>().call(
          query: query,
          accountId: widget.parentAccountId,
        );
        if (mounted && requestId == _searchRequestId) {
          setState(() => _suggestions = results);
        }
      } catch (_) {
        // A stale-cache lookup failing is not worth surfacing here — the
        // user can still type the full address and add it directly.
      }
    });
  }

  Future<void> _selectCandidate(String email) async {
    setState(() {
      _isChecking = true;
      _error = null;
    });
    try {
      final cubit = context.read<AccountCubit>();
      final result = await cubit.resolveSharedMailboxCandidate(
        widget.parentAccountId,
        email,
      );
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _error = '$email was not found in the directory.';
          _isChecking = false;
        });
        return;
      }
      if (result.needsReauth) {
        setState(() {
          _error =
              '${widget.parentAccountLabel} needs to be re-authenticated '
              '(Settings > Accounts) before it can open shared mailboxes.';
          _isChecking = false;
        });
        return;
      }
      if (!result.hasAccess) {
        setState(() {
          _error =
              "Couldn't open $email — you may not have Full Access on it, or "
              '${widget.parentAccountLabel} may need re-authenticating from '
              'Settings.';
          _isChecking = false;
        });
        return;
      }
      await cubit.addSharedMailbox(
        parentAccountId: widget.parentAccountId,
        email: email,
        displayName: result.displayName,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not add $email: $e';
          _isChecking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final query = _queryCtrl.text.trim();
    final showTypedOption =
        _looksLikeEmail.hasMatch(query) &&
        !_suggestions.any(
          (s) => s.address.toLowerCase() == query.toLowerCase(),
        );

    return AlertDialog(
      title: const Text('Add Shared Mailbox'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add a mailbox you have Full Access to on ${widget.parentAccountLabel}.',
                style: TextStyle(color: c.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _queryCtrl,
                focusNode: _queryFocus,
                enabled: !_isChecking,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name or email address',
                ),
                onChanged: _onQueryChanged,
                onSubmitted: (v) {
                  final trimmed = v.trim();
                  if (_looksLikeEmail.hasMatch(trimmed)) {
                    _selectCandidate(trimmed);
                  }
                },
              ),
              const SizedBox(height: 8),
              if (_isChecking)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (_suggestions.isNotEmpty || showTypedOption)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final s in _suggestions)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            s.name != null && s.name!.isNotEmpty
                                ? s.name!
                                : s.address,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: s.name != null && s.name!.isNotEmpty
                              ? Text(
                                  s.address,
                                  style: TextStyle(
                                    color: c.textMuted,
                                    fontSize: 11,
                                  ),
                                )
                              : null,
                          onTap: () => _selectCandidate(s.address),
                        ),
                      if (showTypedOption)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.add, size: 18),
                          title: Text(
                            'Add "$query"',
                            style: const TextStyle(fontSize: 13),
                          ),
                          onTap: () => _selectCandidate(query),
                        ),
                    ],
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFEF4444),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          // Always enabled, even mid-probe: _selectCandidate's `mounted`
          // checks make an early pop safe, and a throttled tenant must not
          // leave the user stuck behind a frozen modal.
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
