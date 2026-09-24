import 'package:flutter/material.dart';
import '../../widgets/adaptive_switch.dart';
import '../../widgets/adaptive_alert_dialog.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/platform/touch_metrics.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/consumer_email_domain.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/out_of_office_settings.dart';
import '../../../injection_container.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../blocs/account/account_cubit.dart';
import '../../blocs/out_of_office/out_of_office_cubit.dart';
import '../../blocs/out_of_office/out_of_office_state.dart';
import '../../widgets/compose_body_builder.dart';
import '../../widgets/date_time_fields.dart';
import '../../widgets/html_email_editor.dart';
import '../../widgets/insert_link_dialog.dart';
import 'meeting_sweep_dialog.dart';

/// The Out of Office settings section.
///
/// Edits the mailbox's *server-side* automatic reply — Graph's
/// `automaticRepliesSetting`, Gmail's vacation responder — so nothing here is
/// stored by the app and the setting applies however the user reads their
/// mail. Self-contained the way [AiSettingsPage] is: it builds its own cubit
/// from `get_it` rather than relying on the host dialog's provider subtree,
/// which matters because `SettingsDialog.open`'s `wrap()` is not the only
/// provider site — the mobile section route builds its own, narrower one.
class OutOfOfficePage extends StatelessWidget {
  const OutOfOfficePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<OutOfOfficeCubit>(
      create: (_) => sl<OutOfOfficeCubit>()..load(),
      child: const _OutOfOfficeView(),
    );
  }
}

class _OutOfOfficeView extends StatefulWidget {
  const _OutOfOfficeView();

  @override
  State<_OutOfOfficeView> createState() => _OutOfOfficeViewState();
}

class _OutOfOfficeViewState extends State<_OutOfOfficeView> {
  final _htmlEditorKey = GlobalKey<HtmlEmailEditorState>();
  final _plainController = TextEditingController();

  EmailBodyType _composeFormat = AppSettings.defaultComposeFormat;

  /// Which reply body the editor is showing. Only Microsoft ever has two.
  OutOfOfficeMessageSlot _slot = OutOfOfficeMessageSlot.internal;

  /// Swap bookkeeping for the single editor instance shared by the two
  /// message bodies. See [_selectSlot] and [_onEditorChanged].
  int _swapId = 0;
  int _settledSwapId = 0;
  bool get _swapping => _swapId != _settledSwapId;

  /// What the plain-text controller currently holds. Tracked as an
  /// (account, slot) pair rather than just the account: the compose-format
  /// preference is loaded *asynchronously*, so the plain field always mounts
  /// on a rebuild rather than the first paint — and if the tab had moved by
  /// then, filling it from the internal body would write that text into the
  /// external one on the first keystroke.
  String? _loadedAccountId;
  OutOfOfficeMessageSlot? _loadedSlot;

  @override
  void initState() {
    super.initState();
    sl<AppSettings>().loadDefaultComposeFormat().then((format) {
      if (mounted) setState(() => _composeFormat = format);
    });
  }

  @override
  void dispose() {
    _plainController.dispose();
    super.dispose();
  }

  // ─── The message editor ──────────────────────────────────────────────────

  String _bodyFor(OutOfOfficeSettings? settings, OutOfOfficeMessageSlot slot) {
    if (settings == null) return '';
    return switch (slot) {
      OutOfOfficeMessageSlot.internal => settings.messageHtml,
      OutOfOfficeMessageSlot.external => settings.externalMessageHtml,
    };
  }

  /// Routes an edit to whichever body the editor is showing.
  ///
  /// Dropped while a swap is in flight. The editor debounces changes by 300 ms
  /// and defers the notification through `requestIdleCallback`, so an edit made
  /// just before a tab press can arrive *after* the press — and the payload is
  /// read from the DOM when it fires, not when it was scheduled. That makes a
  /// late event harmless once the new document is in place (it simply reports
  /// the new body) and wrong in exactly one window: after the tab has flipped
  /// but before `setContent` has landed, where it would write the outgoing
  /// body into the incoming slot.
  void _onEditorChanged(String html) {
    if (_swapping) return;
    context.read<OutOfOfficeCubit>().setMessageFor(_slot, html);
  }

  Future<void> _selectSlot(OutOfOfficeMessageSlot slot) async {
    if (slot == _slot) return;
    final cubit = context.read<OutOfOfficeCubit>();
    final from = _slot;
    // Monotonic rather than a bool: two fast tab presses interleave, and only
    // the last one may declare the editor settled. Same shape as
    // `_searchRequestId` in recipient_input_field.dart.
    final id = ++_swapId;

    if (_composeFormat == EmailBodyType.html) {
      final editor = _htmlEditorKey.currentState;
      // Flush by hand: the pending debounce holds the last keystrokes, and
      // they belong to the body being left.
      if (editor != null) {
        final html = await editor.getContent();
        if (!mounted || id != _swapId) return;
        cubit.setMessageFor(from, html);
      }
      setState(() => _slot = slot);
      await editor?.setContent(_bodyFor(cubit.state.draft, slot));
    } else {
      cubit.setMessageFor(
        from,
        ComposeBodyBuilder.plainToHtml(_plainController.text),
      );
      // The refill is left to build, which is the only place that fills this
      // controller — doing it here as well would run twice and reset the
      // caret on the second pass.
      setState(() => _slot = slot);
    }

    if (!mounted) return;
    // A swap overtaken by a later one never settles; the later one does.
    if (id == _swapId) setState(() => _settledSwapId = id);
  }

  Future<void> _onLinkRequested() async {
    final editorState = _htmlEditorKey.currentState;
    if (editorState != null) await editorState.hide();
    if (!mounted) return;
    final url = await showInsertLinkDialog(context);
    if (mounted && editorState != null) await editorState.show();
    if (url != null && url.isNotEmpty) {
      _htmlEditorKey.currentState?.insertLink(url);
    }
  }

  // ─── Saving ──────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final cubit = context.read<OutOfOfficeCubit>();

    // The editor's last 300 ms of typing is still in the webview. Saving
    // without collecting it drops whatever was typed just before the press —
    // which on a short message is most of it.
    if (_composeFormat == EmailBodyType.html) {
      final editor = _htmlEditorKey.currentState;
      if (editor != null) {
        final html = await editor.getContent();
        if (!mounted) return;
        cubit.setMessageFor(_slot, html);
      }
    }

    if (cubit.state.needsPermission) {
      // Say that the provider is about to ask, *before* running the flow —
      // springing a browser window on somebody who has just pressed Save is
      // the thing this avoids. Same shape as the empty-trash consent dialog.
      if (!mounted) return;
      final proceed = await _confirmPermission();
      if (proceed != true) return;
      final granted = await cubit.requestPermission();
      // A decline is an answer, not an error: nothing has been changed, so
      // there is nothing to report and nothing to save.
      if (!granted) return;
    }

    // Captured before the save so the sweep only offers itself on the save
    // that actually *turns on* automatic replies — not on every later save
    // that only edits the message or audience while it is already on, which
    // would otherwise reopen the dialog for meetings already handled.
    final wasEnabled = cubit.state.saved?.enabled ?? false;
    final willEnable = cubit.state.draft?.enabled ?? false;
    final accountId = cubit.state.accountId;
    final window = cubit.state.draft;
    final savedAtBefore = cubit.state.savedAt;

    await cubit.save();
    if (!mounted) return;

    final saveSucceeded = cubit.state.savedAt != savedAtBefore;
    if (saveSucceeded &&
        !wasEnabled &&
        willEnable &&
        accountId != null &&
        window?.start != null &&
        window?.end != null) {
      await showMeetingSweepDialog(
        context,
        accountId: accountId,
        start: window!.start!,
        end: window.end!,
      );
    }
  }

  Future<bool?> _confirmPermission() {
    final isGoogle = _account() is GmailAccount;
    final provider = isGoogle ? 'Google' : 'Microsoft';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AdaptiveAlertDialog(
        title: const Text('Permission needed'),
        content: Text(
          'Saving an out-of-office reply needs one extra permission on this '
          'account. $provider will ask you to sign in and approve it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  /// The account being edited, which decides how the audience options are
  /// worded and whether the internal/external split exists at all.
  Account? _account() {
    final id = context.read<OutOfOfficeCubit>().state.accountId;
    final state = context.read<AccountCubit>().state;
    if (id == null || state is! AccountsLoaded) return null;
    for (final a in state.accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocConsumer<OutOfOfficeCubit, OutOfOfficeState>(
      listenWhen: (a, b) => a.savedAt != b.savedAt && b.savedAt != null,
      listener: (context, state) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Out of office settings saved')),
        );
      },
      builder: (context, state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AccountPicker(),
            const SizedBox(height: 16),
            Expanded(child: _body(context, state, c)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, OutOfOfficeState state, AppColors c) {
    switch (state.status) {
      case OutOfOfficeStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case OutOfOfficeStatus.unsupported:
        return _Notice(
          icon: Icons.info_outline_rounded,
          text:
              state.errorMessage ??
              'Out of office replies are not available for this account.',
        );
      case OutOfOfficeStatus.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Notice(
              icon: Icons.error_outline_rounded,
              text:
                  state.errorMessage ??
                  'Could not load out of office settings.',
              isError: true,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.read<OutOfOfficeCubit>().load(),
              style: TextButton.styleFrom(foregroundColor: AppColors.accent),
              child: const Text('Try again'),
            ),
          ],
        );
      case OutOfOfficeStatus.ready:
        return _form(context, state, c);
    }
  }

  Widget _form(BuildContext context, OutOfOfficeState state, AppColors c) {
    final cubit = context.read<OutOfOfficeCubit>();
    final draft = state.draft!;
    final enabled = draft.enabled;
    final account = _account();
    // Only Microsoft distinguishes an internal audience from an external one.
    // Gmail has a single body in two renderings, so there is nothing to split.
    final hasExternalSplit = account is MicrosoftAccount;
    final showTabs = hasExternalSplit && draft.useSeparateExternalMessage;

    // Refill the plain field when the mailbox or the tab changes — never on
    // the text changing, or every keystroke would put the caret back at the
    // start. A new mailbox also resets the tab: it may not even have two
    // bodies to show.
    if (_loadedAccountId != state.accountId) {
      _loadedAccountId = state.accountId;
      _slot = OutOfOfficeMessageSlot.internal;
      _loadedSlot = null;
    }
    if (_loadedSlot != _slot) {
      _loadedSlot = _slot;
      _plainController.text = ComposeBodyBuilder.stripHtml(
        _bodyFor(draft, _slot),
      );
    }

    // Anything that takes the second message away while the editor is showing
    // it has to put the editor back. The two user-driven paths (the checkbox,
    // and narrowing the audience) swap first and then change the state, so
    // this rarely fires — but it makes the invariant unconditional, and it
    // cannot be done during build.
    if (_slot == OutOfOfficeMessageSlot.external && !showTabs && !_swapping) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectSlot(OutOfOfficeMessageSlot.internal);
      });
    }

    final editor = Opacity(
      opacity: enabled ? 1 : 0.4,
      child: ExcludeFocus(
        excluding: !enabled,
        child: IgnorePointer(
          ignoring: !enabled,
          child: SizedBox(
            height: 160,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: c.surfaceBase,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.separatorStrong),
              ),
              child: _composeFormat == EmailBodyType.html
                  ? HtmlEmailEditor(
                      // Keyed on the account so switching mailboxes
                      // reloads the editor with that mailbox's message.
                      // *Not* on the slot: the two bodies share one
                      // webview and are swapped through setContent, since
                      // rebuilding a platform view per tab press is both
                      // slow and a chance to lose the last keystrokes.
                      key: ValueKey('ooo-${state.accountId}'),
                      initialHtml: state.saved?.messageHtml ?? '',
                      onContentChanged: _onEditorChanged,
                      onLinkRequested: _onLinkRequested,
                      onAttachRequested: () {},
                    )
                  : Padding(
                      padding: const EdgeInsets.all(10),
                      child: TextField(
                        controller: _plainController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          hintText:
                              "e.g.\n\nI'm away until Friday and "
                              'will reply when I get back.',
                          hintStyle: TextStyle(
                            color: c.textMuted,
                            fontSize: 13,
                          ),
                          border: InputBorder.none,
                          isCollapsed: true,
                        ),
                        onChanged: (text) => _onEditorChanged(
                          ComposeBodyBuilder.plainToHtml(text),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );

    // On the desktop the message editor is html_view's native overlay
    // (WebView2/WKWebView), whose screen position is only recalculated on
    // layout, never on scroll deltas — nested in a scroll view it visually
    // detaches from the rest of the form. So there the fields scroll and the
    // editor gets a fixed area below, the same shape (and the same height) as
    // the signature editor in `_AccountsSection`. On a phone the editor is a
    // real platform view that scrolls with the form, and the fixed area only
    // squeezed the fields under a 160px box once the keyboard was up.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Send automatic replies',
                      style: TextStyle(color: c.textSecondary, fontSize: 13),
                    ),
                    const Spacer(),
                    AdaptiveSwitch(
                      value: enabled,
                      onChanged: state.saving ? null : cubit.setEnabled,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Dimmed is not the same as out of reach: IgnorePointer stops
                // the mouse but leaves these in the focus traversal, so the
                // switch could be off and the pickers still openable from the
                // keyboard. This app is keyboard-forward by design.
                Opacity(
                  opacity: enabled ? 1 : 0.4,
                  child: ExcludeFocus(
                    excluding: !enabled,
                    child: IgnorePointer(
                      ignoring: !enabled,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _DateRow(
                            label: 'Start',
                            date: draft.start,
                            onPicked: cubit.setStartDate,
                          ),
                          const SizedBox(height: 8),
                          _DateRow(
                            label: 'End',
                            date: draft.end,
                            // Inclusive — replies stop at the end of the day
                            // chosen, not at the start of it.
                            onPicked: cubit.setEndDate,
                          ),
                          const SizedBox(height: 8),
                          _AudienceRow(
                            audience: draft.audience,
                            account: account,
                            onChanged: (a) async {
                              // Narrowing to "organisation only" switches the
                              // second message off, so collect the body being
                              // left before the tab bar goes with it.
                              if (a == OutOfOfficeAudience.organisationOnly &&
                                  _slot == OutOfOfficeMessageSlot.external) {
                                await _selectSlot(
                                  OutOfOfficeMessageSlot.internal,
                                );
                              }
                              cubit.setAudience(a);
                            },
                          ),
                          if (hasExternalSplit) ...[
                            const SizedBox(height: 8),
                            _SeparateMessageRow(
                              value: draft.useSeparateExternalMessage,
                              // Nobody outside the organisation is answered,
                              // so a second message would go to no one. The
                              // control is disabled with the reason rather
                              // than hidden — one that vanishes reads as a
                              // bug.
                              enabled: draft.repliesToExternalSenders,
                              onChanged: (v) async {
                                // Collect the body being left before the tab
                                // bar disappears under it.
                                if (!v &&
                                    _slot == OutOfOfficeMessageSlot.external) {
                                  await _selectSlot(
                                    OutOfOfficeMessageSlot.internal,
                                  );
                                }
                                cubit.setUseSeparateExternalMessage(v);
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (enabled && state.hasEmptyMessage) ...[
                  const SizedBox(height: 10),
                  const _Notice(
                    icon: Icons.info_outline_rounded,
                    // Save is disabled in this state; without this the button
                    // is simply grey and nothing says why.
                    text:
                        'Add a message before turning automatic replies on — '
                        'an empty reply would be sent to everybody who writes.',
                  ),
                ],
                if (state.hasDateOrderError) ...[
                  const SizedBox(height: 10),
                  const _Notice(
                    icon: Icons.error_outline_rounded,
                    text: 'The end date must not be before the start date.',
                    isError: true,
                  ),
                ],
                const SizedBox(height: 16),
                _MessageHeader(
                  slot: _slot,
                  showTabs: showTabs,
                  onSelect: _selectSlot,
                ),
                if (isTouchPlatform) ...[
                  const SizedBox(height: 8),
                  editor,
                ],
              ],
            ),
          ),
        ),
        if (!isTouchPlatform) ...[
          const SizedBox(height: 8),
          editor,
        ],
        const SizedBox(height: 12),
        if (state.errorMessage != null) ...[
          _Notice(
            icon: Icons.error_outline_rounded,
            text: state.errorMessage!,
            isError: true,
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            if (state.needsPermission)
              Expanded(
                child: Text(
                  'Saving needs one extra permission — you will be asked for '
                  'it the first time.',
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                ),
              )
            else
              const Spacer(),
            const SizedBox(width: 12),
            if (state.saving)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              FilledButton(
                onPressed: state.canSave && state.isDirty ? _save : null,
                child: const Text('Save'),
              ),
          ],
        ),
      ],
    );
  }
}

// ─── Rows ──────────────────────────────────────────────────────────────────

/// Picks the mailbox being edited. Hidden when only one account is signed in —
/// there is nothing to choose, and a one-item dropdown reads as a control that
/// does not work.
class _AccountPicker extends StatelessWidget {
  const _AccountPicker();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AccountCubit, AccountState>(
      builder: (context, accountState) {
        if (accountState is! AccountsLoaded ||
            accountState.accounts.length < 2) {
          return const SizedBox.shrink();
        }
        return BlocBuilder<OutOfOfficeCubit, OutOfOfficeState>(
          builder: (context, state) {
            final ids = accountState.accounts.map((a) => a.id).toList();
            final value = ids.contains(state.accountId)
                ? state.accountId
                : null;
            return _SettingRow(
              label: 'Account',
              child: _Dropdown<String>(
                value: value,
                items: [
                  for (final a in accountState.accounts)
                    DropdownMenuItem(
                      value: a.id,
                      child: Text(
                        a.emailAddress,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: state.saving
                    ? null
                    : (id) {
                        if (id != null) {
                          context.read<OutOfOfficeCubit>().load(id);
                        }
                      },
              ),
              width: 280,
            );
          },
        );
      },
    );
  }
}

/// How an audience is worded for [account].
///
/// Per provider, because the two genuinely differ: Microsoft always answers
/// everyone inside the organisation and the choice governs only outsiders,
/// while Gmail's `restrictToContacts` is the whole rule — a colleague who is
/// not a contact gets nothing. Labelling both "my contacts" would be wrong for
/// one of them.
String outOfOfficeAudienceLabel(
  OutOfOfficeAudience audience,
  Account? account,
) {
  final isGoogle = account is GmailAccount;
  return switch (audience) {
    OutOfOfficeAudience.everyone => 'Everyone',
    OutOfOfficeAudience.contacts =>
      isGoogle ? 'People in my contacts' : 'My organisation and my contacts',
    OutOfOfficeAudience.organisationOnly =>
      isGoogle ? 'People in my organisation only' : 'My organisation only',
  };
}

/// The audience options [account] can actually honour.
///
/// Gmail's "organisation only" is `restrictToDomain`, which means nothing on a
/// personal `@gmail.com` — offering it there would be a control that silently
/// does nothing. It is still listed when the mailbox is already set that way,
/// because a dropdown whose current value is missing from its own items
/// throws.
List<OutOfOfficeAudience> outOfOfficeAudienceOptions(
  Account? account,
  OutOfOfficeAudience current,
) {
  final consumerGoogle =
      account is GmailAccount && isConsumerGoogleAddress(account.emailAddress);
  return [
    for (final a in OutOfOfficeAudience.values)
      if (a == current ||
          !(consumerGoogle && a == OutOfOfficeAudience.organisationOnly))
        a,
  ];
}

class _AudienceRow extends StatelessWidget {
  const _AudienceRow({
    required this.audience,
    required this.account,
    required this.onChanged,
  });

  final OutOfOfficeAudience audience;
  final Account? account;
  final ValueChanged<OutOfOfficeAudience> onChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingRow(
      label: 'Reply to',
      width: 280,
      child: _Dropdown<OutOfOfficeAudience>(
        value: audience,
        items: [
          for (final a in outOfOfficeAudienceOptions(account, audience))
            DropdownMenuItem(
              value: a,
              child: Text(
                outOfOfficeAudienceLabel(a, account),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

class _SeparateMessageRow extends StatelessWidget {
  const _SeparateMessageRow({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Different message for people outside my organisation',
                style: TextStyle(
                  color: enabled ? c.textSecondary : c.textMuted,
                  fontSize: 13,
                ),
              ),
              if (!enabled)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Nobody outside your organisation is being replied to.',
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Checkbox(
          value: value,
          onChanged: enabled
              ? (v) {
                  if (v != null) onChanged(v);
                }
              : null,
        ),
      ],
    );
  }
}

/// "Message", plus the two-body tab bar when one is in use.
class _MessageHeader extends StatelessWidget {
  const _MessageHeader({
    required this.slot,
    required this.showTabs,
    required this.onSelect,
  });

  final OutOfOfficeMessageSlot slot;
  final bool showTabs;
  final ValueChanged<OutOfOfficeMessageSlot> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (!showTabs) {
      return Text(
        'Message',
        style: TextStyle(color: c.textSecondary, fontSize: 13),
      );
    }
    return Row(
      children: [
        Text('Message', style: TextStyle(color: c.textSecondary, fontSize: 13)),
        const Spacer(),
        _SlotTab(
          label: 'Inside my organisation',
          selected: slot == OutOfOfficeMessageSlot.internal,
          onTap: () => onSelect(OutOfOfficeMessageSlot.internal),
        ),
        const SizedBox(width: 4),
        _SlotTab(
          label: 'Outside',
          selected: slot == OutOfOfficeMessageSlot.external,
          onTap: () => onSelect(OutOfOfficeMessageSlot.external),
        ),
      ],
    );
  }
}

class _SlotTab extends StatelessWidget {
  const _SlotTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? c.surfaceBase : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? c.separatorStrong : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? c.textPrimary : c.textMuted,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.label,
    required this.date,
    required this.onPicked,
  });

  final String label;
  final DateTime? date;
  final ValueChanged<DateTime> onPicked;

  @override
  Widget build(BuildContext context) {
    final shown = date ?? DateTime.now();
    return _SettingRow(
      label: label,
      width: 280,
      child: Align(
        alignment: Alignment.centerRight,
        child: DateFieldButton(
          date: shown,
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: shown,
              // A window that started in the past is a normal thing to edit —
              // an out-of-office already running, for instance — so the range
              // reaches back as well as forward.
              firstDate: DateTime(shown.year - 1),
              lastDate: DateTime(shown.year + 5),
            );
            if (picked != null) onPicked(picked);
          },
        ),
      ),
    );
  }
}

// ─── Shared bits ───────────────────────────────────────────────────────────

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.child,
    this.width = 180,
  });

  final String label;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Text(label, style: TextStyle(color: c.textSecondary, fontSize: 13)),
        const Spacer(),
        SizedBox(width: width, child: child),
      ],
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          dropdownColor: c.surfacePanel,
          style: TextStyle(color: c.textSecondary, fontSize: 13),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.isError = false});

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = isError ? Colors.redAccent : c.textMuted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }
}
