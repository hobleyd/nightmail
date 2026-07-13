import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../injection_container.dart';
import '../../core/settings/app_settings.dart';
import '../../core/signature/signature_merge_engine.dart';
import '../../core/theme/app_colors.dart';
import '../../infrastructure/accounts/account.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_attachment.dart';
import '../../domain/entities/local_attachment.dart';
import '../../domain/usecases/delete_server_draft.dart';
import '../../domain/usecases/download_attachment.dart';
import '../../domain/usecases/save_server_draft.dart';
import '../../domain/usecases/send_email.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/ai/ai_compose_cubit.dart';
import '../blocs/ai/ai_compose_state.dart';
import '../blocs/compose/compose_bloc.dart';
import '../blocs/compose/compose_event.dart';
import '../blocs/compose/compose_state.dart';
import 'compose_body_builder.dart';
import 'html_email_editor.dart';
import 'insert_link_dialog.dart';
import 'recipient_input_field.dart';

class ComposeDialog extends StatelessWidget {
  const ComposeDialog({
    super.key,
    required this.mode,
    this.originalEmail,
    this.draftEmail,
    required this.fromAddress,
    this.accountId,
    this.accountDomain,
    this.accounts = const [],
    required this.defaultComposeFormat,
    this.signatureHtml = '',
  });

  final ComposeMode mode;
  final Email? originalEmail;
  final Email? draftEmail;
  final String fromAddress;
  final String? accountId;
  final String? accountDomain;
  final List<Account> accounts;
  final EmailBodyType defaultComposeFormat;
  final String signatureHtml;

  static Future<void> show(
    BuildContext context, {
    required ComposeMode mode,
    Email? originalEmail,
    Email? draftEmail,
  }) async {
    final accountState = context.read<AccountCubit>().state;
    final fromAddress = accountState is AccountsLoaded
        ? () {
            final account = accountState.activeAccount;
            final name = account.senderName;
            final email = account.emailAddress;
            return name.isNotEmpty ? '$name <$email>' : email;
          }()
        : '';
    final accountId =
        accountState is AccountsLoaded ? accountState.activeAccount.id : null;
    final accountDomain = accountState is AccountsLoaded
        ? _domainOf(accountState.activeAccount.emailAddress)
        : null;
    final accounts =
        accountState is AccountsLoaded ? accountState.accounts : const <Account>[];
    final defaultFormat = await sl<AppSettings>().loadDefaultComposeFormat();
    final signatureHtml = accountState is AccountsLoaded
        ? SignatureMergeEngine.merge(
            accountState.activeAccount.signatureHtml, accountState.activeAccount)
        : '';
    if (!context.mounted) return;
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => BlocProvider(
        create: (_) => ComposeBloc(sendEmail: sl<SendEmail>()),
        child: ComposeDialog(
          mode: mode,
          originalEmail: originalEmail,
          draftEmail: draftEmail,
          fromAddress: fromAddress,
          accountId: accountId,
          accountDomain: accountDomain,
          accounts: accounts,
          defaultComposeFormat: defaultFormat,
          signatureHtml: signatureHtml,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).pop();
    return BlocListener<ComposeBloc, ComposeState>(
      listener: (listenerContext, state) {
        if (state is ComposeSent) {
          Navigator.of(listenerContext).pop();
          ScaffoldMessenger.of(listenerContext).showSnackBar(
            const SnackBar(
              content: Text('Email sent'),
              duration: Duration(seconds: 2),
            ),
          );
        } else if (state is ComposeError) {
          ScaffoldMessenger.of(listenerContext).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      },
      child: Dialog(
        backgroundColor: context.colors.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ComposeForm(
          mode: mode,
          originalEmail: originalEmail,
          draftEmail: draftEmail,
          onClose: close,
          fromAddress: fromAddress,
          accountId: accountId,
          accountDomain: accountDomain,
          accounts: accounts,
          defaultComposeFormat: defaultComposeFormat,
          signatureHtml: signatureHtml,
        ),
      ),
    );
  }

  static String? _domainOf(String email) {
    final at = email.lastIndexOf('@');
    if (at < 0 || at == email.length - 1) return null;
    return email.substring(at + 1).toLowerCase();
  }
}

class ComposeForm extends StatefulWidget {
  const ComposeForm({
    super.key,
    required this.mode,
    this.originalEmail,
    this.draftEmail,
    required this.onClose,
    required this.fromAddress,
    this.accountId,
    this.accountDomain,
    this.accounts = const [],
    this.scrollable = false,
    this.existingDraftId,
    this.onTitleChanged,
    required this.defaultComposeFormat,
    this.signatureHtml = '',
  });

  final ComposeMode mode;
  final Email? originalEmail;
  final Email? draftEmail;
  final VoidCallback onClose;
  final String fromAddress;
  final String? accountId;
  final String? accountDomain;
  final List<Account> accounts;
  final bool scrollable;
  final String? existingDraftId;
  final ValueChanged<String>? onTitleChanged;
  final EmailBodyType defaultComposeFormat;
  final String signatureHtml;

  @override
  State<ComposeForm> createState() => _ComposeFormState();
}

class _ComposeFormState extends State<ComposeForm> {
  late List<String> _toRecipients;
  late List<String> _ccRecipients;
  final _toFieldKey = GlobalKey<RecipientInputFieldState>();
  final _ccFieldKey = GlobalKey<RecipientInputFieldState>();
  late String? _selectedAccountId;
  late final TextEditingController _subjectController;
  late final TextEditingController _bodyController;
  final FocusNode _subjectFocus = FocusNode();
  final FocusNode _bodyFocus = FocusNode();
  List<String> _excludedAttachmentIds = [];
  List<LocalAttachment> _localAttachments = [];
  bool _isDragOver = false;

  late EmailBodyType _bodyType;
  // Tracks the latest HTML from the WebView (updated on every change event).
  String _htmlBodyCache = '';
  final _htmlEditorKey = GlobalKey<HtmlEmailEditorState>();

  // AI compose / smart-reply streaming.
  late final AiComposeCubit _aiCubit;
  // Length of the AI text already inserted into the editor this generation, so
  // each streaming state inserts only the new delta at the caret.
  int _aiInsertedLen = 0;
  bool _aiGenerating = false;
  // Snapshot of the editor HTML taken when an AI draft starts. On the terminal
  // [AiComposeDone] we rebuild the editor as base + full draft if the streamed
  // inserts couldn't be trusted (e.g. the webview was still mounting), so no
  // streamed tokens are ever permanently lost (M3).
  String _aiBaseHtml = '';
  // True when the editor was (re)mounted for this generation (plain → HTML
  // switch). The streamed caret is lost across the remount and early deltas can
  // race the fresh webview, so on Done we reconcile the full draft via
  // setContent rather than trusting [_aiInsertedLen].
  bool _aiReconcileFull = false;

  String? _serverDraftId;
  String? _pendingOldDraftId;
  Timer? _draftTimer;
  DateTime? _lastDraftSavedAt;
  bool _sent = false;
  // Tracks an in-flight _saveDraft() call so _submit() can await it and
  // collect the ID of any draft created after _sent was set to true.
  Completer<String?>? _saveCompleter;

  static const _kDraftsRefreshChannel =
      MethodChannel('au.com.sharpblue.nightmail/drafts_refresh');

  @override
  void initState() {
    super.initState();
    _aiCubit = sl<AiComposeCubit>();
    _toRecipients = _parseAddresses(_initialTo());
    _ccRecipients = _parseAddresses(_initialCc());
    _selectedAccountId = widget.accountId ??
        (widget.accounts.isNotEmpty ? widget.accounts.first.id : null);
    _subjectController = TextEditingController(text: _initialSubject());

    _bodyType = _determineInitialBodyType();
    if (_bodyType == EmailBodyType.html) {
      _htmlBodyCache = _buildInitialHtmlBody();
      _bodyController = TextEditingController();
    } else {
      _bodyController = TextEditingController(text: _buildInitialPlainBody());
    }

    _subjectFocus.onKeyEvent = (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.tab) {
        _focusBodyEditor();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    _subjectController.addListener(_onSubjectChanged);
    _bodyController.addListener(_scheduleDraftSave);

    _serverDraftId = widget.existingDraftId;
    _pendingOldDraftId = widget.existingDraftId;

    if (widget.existingDraftId != null &&
        widget.draftEmail != null &&
        widget.draftEmail!.attachments.isNotEmpty) {
      _loadDraftAttachments(
          widget.existingDraftId!, widget.draftEmail!.attachments);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final isReply = widget.mode == ComposeMode.reply ||
          widget.mode == ComposeMode.replyAll;
      // Leading quoted text and/or a signature put the cursor's natural home
      // at the very start of the body, not wherever the controller defaults to.
      if (_bodyType == EmailBodyType.text && _bodyController.text.isNotEmpty) {
        _bodyController.selection = const TextSelection.collapsed(offset: 0);
      }
      if (isReply) {
        if (_bodyType == EmailBodyType.text) {
          _bodyFocus.requestFocus();
        }
        // Else: the HTML editor autofocuses itself once its content finishes
        // loading (see HtmlEmailEditor.autofocus in _buildBodyEditor).
      } else {
        _toFieldKey.currentState?.requestFocus();
      }
      widget.onTitleChanged?.call(_title);
    });
  }

  @override
  void didUpdateWidget(ComposeForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the parent resolved the initial account after first build (e.g.
    // account email backfill), push the updated default — but only if the
    // user hasn't already picked a different account themselves.
    if (widget.accountId != oldWidget.accountId &&
        _selectedAccountId == oldWidget.accountId) {
      _selectedAccountId = widget.accountId;
    }
  }

  void _focusBodyEditor() {
    if (_bodyType == EmailBodyType.html) {
      FocusManager.instance.primaryFocus?.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _htmlEditorKey.currentState?.focus();
      });
    } else {
      _bodyFocus.requestFocus();
    }
  }

  EmailBodyType _determineInitialBodyType() {
    if (widget.draftEmail != null) return widget.draftEmail!.bodyType;
    if (widget.originalEmail != null) return widget.originalEmail!.bodyType;
    return widget.defaultComposeFormat;
  }

  String _buildInitialPlainBody() => ComposeBodyBuilder.buildInitialPlainBody(
        originalEmail: widget.originalEmail,
        draftEmail: widget.draftEmail,
        mode: widget.mode,
        signature: ComposeBodyBuilder.stripHtml(widget.signatureHtml),
      );

  String _buildInitialHtmlBody() => ComposeBodyBuilder.buildInitialHtmlBody(
        originalEmail: widget.originalEmail,
        draftEmail: widget.draftEmail,
        mode: widget.mode,
        signature: widget.signatureHtml,
      );

  List<String> _parseAddresses(String text) {
    if (text.trim().isEmpty) return [];
    return text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }

  String _bareAddress(String address) {
    final match = RegExp(r'<([^>]+)>').firstMatch(address);
    return (match?.group(1) ?? address).trim();
  }

  Account? get _selectedAccount => widget.accounts
      .cast<Account?>()
      .firstWhere((a) => a?.id == _selectedAccountId, orElse: () => null);

  String? get _selectedAccountDomain {
    final email = _selectedAccount?.emailAddress;
    if (email == null) return widget.accountDomain;
    final at = email.lastIndexOf('@');
    if (at < 0 || at == email.length - 1) return widget.accountDomain;
    return email.substring(at + 1).toLowerCase();
  }

  static List<String> _dedupAddresses(List<String> addresses) {
    final seen = <String>{};
    return addresses.where((a) => seen.add(a.toLowerCase())).toList();
  }

  String _initialTo() {
    if (widget.draftEmail != null) {
      return widget.draftEmail!.toRecipients.map((r) => r.address).join(', ');
    }
    final email = widget.originalEmail;
    if (email == null) return '';
    return switch (widget.mode) {
      ComposeMode.reply => email.from.address,
      ComposeMode.replyAll => _dedupAddresses([
          email.from.address,
          ...email.toRecipients.map((r) => r.address),
        ].where((a) => a.toLowerCase() != _bareAddress(widget.fromAddress).toLowerCase()).toList()).join(', '),
      ComposeMode.forward => '',
      ComposeMode.newEmail => '',
    };
  }

  String _initialCc() {
    if (widget.draftEmail != null) {
      return widget.draftEmail!.ccRecipients.map((r) => r.address).join(', ');
    }
    final email = widget.originalEmail;
    if (email == null) return '';
    return switch (widget.mode) {
      ComposeMode.replyAll => () {
          final myAddress = _bareAddress(widget.fromAddress).toLowerCase();
          final toSet = {
            email.from.address.toLowerCase(),
            ...email.toRecipients.map((r) => r.address.toLowerCase()),
          };
          return _dedupAddresses(
            email.ccRecipients
                .map((r) => r.address)
                .where((a) => a.toLowerCase() != myAddress && !toSet.contains(a.toLowerCase()))
                .toList(),
          ).join(', ');
        }(),
      _ => '',
    };
  }

  static final _rePrefix = RegExp(r'^(?:re:\s*)+', caseSensitive: false);

  String _initialSubject() {
    if (widget.draftEmail != null) return widget.draftEmail!.subject;
    final email = widget.originalEmail;
    if (email == null) return '';
    final subject = email.subject;
    return switch (widget.mode) {
      ComposeMode.reply ||
      ComposeMode.replyAll =>
        'Re: ${subject.replaceFirst(_rePrefix, '').trim()}',
      ComposeMode.forward => 'Fwd: $subject',
      ComposeMode.newEmail => '',
    };
  }

  @override
  void dispose() {
    final hasPendingSave = _draftTimer?.isActive == true;
    final draftId = _serverDraftId;
    final oldDraftId = _pendingOldDraftId;
    final to = List<String>.from(_toRecipients);
    final cc = List<String>.from(_ccRecipients);
    final subject = _subjectController.text;
    final body = _bodyType == EmailBodyType.html
        ? _htmlBodyCache
        : _bodyController.text;
    final bodyType = _bodyType;
    final attachments = List<LocalAttachment>.from(_localAttachments);

    _draftTimer?.cancel();
    _subjectController.removeListener(_onSubjectChanged);
    _bodyController.removeListener(_scheduleDraftSave);
    unawaited(_aiCubit.close());
    _subjectController.dispose();
    _bodyController.dispose();
    _subjectFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();

    if (hasPendingSave) {
      sl<SaveServerDraft>()(SaveServerDraftParams(
        existingDraftId: draftId,
        toAddresses: to,
        ccAddresses: cc,
        subject: subject,
        body: body,
        bodyType: bodyType,
        newAttachments: attachments,
      )).then((result) {
        result.fold((_) {}, (newId) {
          if (oldDraftId != null && newId != oldDraftId) {
            sl<DeleteServerDraft>()(oldDraftId).ignore();
          }
        });
      }).ignore();
    }
  }

  void _onSubjectChanged() {
    setState(() {});
    widget.onTitleChanged?.call(_title);
    _scheduleDraftSave();
  }

  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 1500), _saveDraft);
  }

  Future<String?> _saveDraft() async {
    if (_sent) return null;
    final completer = Completer<String?>();
    _saveCompleter = completer;
    final oldDraftId = _pendingOldDraftId;
    final body = _bodyType == EmailBodyType.html
        ? _htmlBodyCache
        : _bodyController.text;
    try {
      final result = await sl<SaveServerDraft>()(SaveServerDraftParams(
        existingDraftId: _serverDraftId,
        toAddresses: _toRecipients,
        ccAddresses: _ccRecipients,
        subject: _subjectController.text,
        body: body,
        bodyType: _bodyType,
        newAttachments: _localAttachments,
      ));
      return result.fold(
        (failure) {
          completer.complete(null);
          return failure.message;
        },
        (newId) {
          completer.complete(newId);
          if (_sent) {
            // _submit() is waiting on this completer and will delete the draft.
            return null;
          }
          _serverDraftId = newId;
          if (mounted) setState(() => _lastDraftSavedAt = DateTime.now());
          if (oldDraftId != null) {
            _pendingOldDraftId = null;
            if (newId != oldDraftId) {
              sl<DeleteServerDraft>()(oldDraftId).ignore();
            }
          }
          return null;
        },
      );
    } catch (e) {
      if (!completer.isCompleted) completer.complete(null);
      rethrow;
    } finally {
      if (_saveCompleter == completer) _saveCompleter = null;
    }
  }

  Future<void> _loadDraftAttachments(
      String draftId, List<EmailAttachment> attachments) async {
    final loaded = <LocalAttachment>[];
    for (final att in attachments) {
      final result = await sl<DownloadAttachment>()(
        DownloadAttachmentParams(messageId: draftId, attachmentId: att.id),
      );
      result.fold(
        (_) {},
        (bytes) => loaded.add(LocalAttachment(
          name: att.name,
          mimeType: att.contentType,
          bytes: bytes,
        )),
      );
    }
    if (mounted && loaded.isNotEmpty) {
      setState(() => _localAttachments = [..._localAttachments, ...loaded]);
    }
  }

  Future<void> _deleteDraft() async {
    if (_serverDraftId == null) return;
    await sl<DeleteServerDraft>()(_serverDraftId!);
    _serverDraftId = null;
  }

  bool get _hasContent {
    final htmlEmpty = _htmlBodyCache.isEmpty ||
        _htmlBodyCache == '<br>' ||
        _htmlBodyCache == '<div><br></div>';
    return _serverDraftId != null ||
        _toRecipients.isNotEmpty ||
        _ccRecipients.isNotEmpty ||
        _subjectController.text.isNotEmpty ||
        (_bodyType == EmailBodyType.html
            ? !htmlEmpty
            : _bodyController.text.isNotEmpty) ||
        _localAttachments.where((a) => !a.isInline).isNotEmpty;
  }

  Future<void> _requestClose(BuildContext context) async {
    if (!_hasContent) {
      widget.onClose();
      return;
    }

    final editorState = _htmlEditorKey.currentState;
    if (editorState != null) await editorState.hide();

    final action = await showDialog<_CloseAction>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const _CloseDraftDialog(),
    );

    if (!mounted) return;
    switch (action) {
      case _CloseAction.saveToDrafts:
        _draftTimer?.cancel();
        final error = await _saveDraft();
        if (!mounted) return;
        if (error == null) {
          widget.onClose();
        } else {
          if (editorState != null) await editorState.show();
          ScaffoldMessenger.of(this.context).showSnackBar(
            SnackBar(
              content: Text('Failed to save draft: $error'),
              backgroundColor: Colors.red.shade700,
              duration: const Duration(seconds: 8),
            ),
          );
        }
      case _CloseAction.delete:
        await _deleteDraft();
        unawaited(_kDraftsRefreshChannel
            .invokeMethod<void>('notifyDraftChanged')
            .catchError((_) {}));
        if (mounted) widget.onClose();
      case null:
        if (editorState != null) await editorState.show();
        break;
    }
  }

  // Switch from HTML to plain text — asks for confirmation because it's lossy.
  Future<void> _switchToPlainText(BuildContext context) async {
    final editorState = _htmlEditorKey.currentState;
    if (editorState != null) await editorState.hide();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: context.colors.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(
          'Switch to Plain Text?',
          style: TextStyle(
            color: context.colors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Switching to plain text will remove all formatting and inline images. '
          'This cannot be undone.',
          style: TextStyle(color: context.colors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Keep HTML',
              style: TextStyle(color: context.colors.textMuted, fontSize: 13),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Switch to Plain Text', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      if (mounted && editorState != null) await editorState.show();
      return;
    }
    if (!mounted) return;
    // confirmed — the HTML editor will be replaced by a plain text field,
    // so there's no need to un-hide it.

    final plainText = _stripHtml(_htmlBodyCache);
    // Remove inline attachments — they don't apply in plain text mode.
    setState(() {
      _bodyType = EmailBodyType.text;
      _localAttachments = _localAttachments.where((a) => !a.isInline).toList();
    });
    _bodyController.text = plainText;
    _scheduleDraftSave();
  }

  void _switchToHtml() {
    final plainText = _bodyController.text;
    final html = _plainToHtml(plainText);
    setState(() {
      _bodyType = EmailBodyType.html;
      _htmlBodyCache = html;
    });
    _htmlEditorKey.currentState?.setContent(html);
    _scheduleDraftSave();
  }

  // ---------------------------------------------------------------------------
  // AI compose / smart-reply
  // ---------------------------------------------------------------------------

  /// Prompts the user for an instruction and kicks off a streaming AI draft.
  Future<void> _onAiCompose(BuildContext context) async {
    // Snapshot the caret BEFORE the prompt dialog steals focus, so the draft
    // streams in where the user placed the cursor (e.g. above a quoted reply).
    final editorState = _htmlEditorKey.currentState;
    await editorState?.saveSelection();

    if (editorState != null) await editorState.hide();
    final instruction = await _promptForAiInstruction(context);
    if (mounted && editorState != null) await editorState.show();

    if (instruction == null || instruction.trim().isEmpty || !mounted) return;

    // AI streaming renders through the HTML (webview) editor; force it on so the
    // tokens land somewhere visible even if the draft started as plain text.
    final remountedEditor = _bodyType != EmailBodyType.html;
    if (remountedEditor) {
      _switchToHtml();
    }

    _aiInsertedLen = 0;
    // Capture the pre-draft content and remount state so the terminal Done can
    // authoritatively rebuild base + full draft if early inserts were dropped.
    _aiBaseHtml = _htmlBodyCache;
    _aiReconcileFull = remountedEditor;

    final original = widget.originalEmail;
    final contextText = original == null
        ? null
        : (original.bodyType == EmailBodyType.html
            ? _stripHtml(original.body)
            : original.body);

    setState(() => _aiGenerating = true);
    _aiCubit.generate(instruction.trim(), context: contextText);
  }

  /// Small modal asking what the AI should write. Returns null on cancel.
  Future<String?> _promptForAiInstruction(BuildContext context) {
    final c = context.colors;
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: c.surfacePanel,
          title: Text(
            'Draft with AI',
            style: TextStyle(color: c.textPrimary, fontSize: 16),
          ),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: controller,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              style: TextStyle(color: c.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Describe the reply you want — e.g. "politely '
                    'decline and suggest meeting next week".',
                hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
              ),
              onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel', style: TextStyle(color: c.textMuted)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Generate'),
            ),
          ],
        );
      },
    );
  }

  /// Reacts to streaming state from [AiComposeCubit], inserting each new token
  /// delta at the saved editor caret via [HtmlEmailEditorState.insertAtCursor]
  /// (no innerHTML rewrite, no caret reset), so the draft streams in smoothly
  /// where the user positioned the cursor.
  /// Inserts any not-yet-rendered portion of [text] at the editor caret.
  void _insertAiDelta(String text) {
    if (text.length <= _aiInsertedLen) return;
    final editor = _htmlEditorKey.currentState;
    // If the editor isn't mounted yet, don't advance the cursor — the missing
    // text is retried on the next delta and finally reconciled on Done, so
    // streamed tokens are never permanently lost (M3).
    if (editor == null) return;
    final delta = text.substring(_aiInsertedLen);
    editor.insertAtCursor(delta);
    // Advance only after a (best-effort) insert against a mounted editor.
    _aiInsertedLen = text.length;
  }

  /// Finalises the streamed AI draft. When the editor was (re)mounted for this
  /// generation the streamed caret/inserts can't be trusted (early deltas may
  /// have raced the fresh webview or been clobbered by its initial setContent),
  /// so we authoritatively rebuild the editor content as base + full draft
  /// rather than relying on [_aiInsertedLen]. Otherwise we flush any trailing
  /// delta into the already-live editor (M3).
  void _finishAiDraft(String text) {
    final editor = _htmlEditorKey.currentState;
    if (editor == null) {
      _aiReconcileFull = false;
      return;
    }
    if (_aiReconcileFull) {
      final full = _aiBaseHtml + _plainToHtml(text);
      editor.setContent(full);
      _htmlBodyCache = full;
      _aiInsertedLen = text.length;
    } else {
      _insertAiDelta(text);
    }
    _aiReconcileFull = false;
  }

  void _onAiComposeStateChanged(BuildContext context, AiComposeState state) {
    switch (state) {
      case AiComposeIdle():
        break;
      case AiComposeStreaming(:final text):
        _insertAiDelta(text);
      case AiComposeDone(:final text):
        _finishAiDraft(text);
        setState(() => _aiGenerating = false);
        _scheduleDraftSave();
      case AiComposeError(:final failure):
        setState(() => _aiGenerating = false);
        // Never surface raw provider/exception text — failure.message can carry
        // verbatim provider error bodies. Log the detail and show a fixed,
        // user-safe message instead (L12).
        debugPrint('AI draft failed: ${failure.message}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              "Couldn't generate the AI draft. Please try again.",
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
    }
  }

  void _addDroppedFiles(DropDoneDetails details) {
    Future.wait(details.files.map((f) async {
      try {
        String name;
        Uint8List bytes;
        if (await FileSystemEntity.isDirectory(f.path)) {
          (name, bytes) = await _readDroppedDirectory(f.path, f.name);
        } else {
          name = f.name;
          bytes = await _readDroppedFileBytes(f.path);
        }
        return LocalAttachment(
          path: f.path,
          name: name,
          mimeType: LocalAttachment.mimeTypeFromName(name),
          bytes: bytes,
        );
      } catch (e, st) {
        debugPrint('Could not attach "${f.name}": $e\n$st');
        return null;
      }
    })).then((results) {
      final added = results.whereType<LocalAttachment>().toList();
      final failCount = results.length - added.length;
      if (!mounted) return;
      if (failCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(failCount == 1
              ? 'Could not attach file: Windows denied access. Try copying it to your Desktop first.'
              : '$failCount files could not be attached: Windows denied access.'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 8),
        ));
      }
      if (added.isEmpty) return;

      if (_bodyType == EmailBodyType.html) {
        // In HTML mode, route image files inline into the editor body.
        final images = added.where((a) => a.mimeType.startsWith('image/')).toList();
        final nonImages = added.where((a) => !a.mimeType.startsWith('image/')).toList();

        for (final img in images) {
          _insertInlineImage(img);
        }
        if (nonImages.isNotEmpty) {
          setState(() => _localAttachments = [..._localAttachments, ...nonImages]);
          _scheduleDraftSave();
        }
      } else {
        setState(() => _localAttachments = [..._localAttachments, ...added]);
        _scheduleDraftSave();
      }
    });
  }

  void _insertInlineImage(LocalAttachment att) {
    final contentId =
        '${DateTime.now().millisecondsSinceEpoch}_${att.name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}@nightmail';
    final inlineAtt = LocalAttachment(
      path: att.path,
      name: att.name,
      mimeType: att.mimeType,
      bytes: att.bytes,
      isInline: true,
      contentId: contentId,
    );
    setState(() => _localAttachments = [..._localAttachments, inlineAtt]);
    final dataUri = 'data:${att.mimeType};base64,${base64.encode(att.bytes)}';
    _htmlEditorKey.currentState?.insertImage(dataUri, contentId);
    _scheduleDraftSave();
  }

  Future<(String, Uint8List)> _readDroppedDirectory(
      String path, String displayName) async {
    if (Platform.isWindows) {
      final extPath = r'\\?\' + path.replaceAll('/', r'\');
      final extEscaped = extPath.replaceAll("'", "''");
      final plainEscaped = path.replaceAll('/', r'\').replaceAll("'", "''");

      final psResult = await Process.run('powershell', [
        '-NoProfile', '-NonInteractive', '-Command',
        "\$p = '$extEscaped'; \$plain = '$plainEscaped';"
            r" $zip = $p.TrimEnd('\') + '.zip';"
            r" if ([IO.File]::Exists($zip)) {"
            r"   Add-Type -AssemblyName System.IO.Compression.FileSystem;"
            r"   $arc = [IO.Compression.ZipFile]::OpenRead($zip);"
            r"   $entry = $arc.Entries|Sort-Object Length -Descending|Select-Object -First 1;"
            r"   if ($entry) {"
            r"     $ms = New-Object IO.MemoryStream; $s = $entry.Open();"
            r"     $s.CopyTo($ms); $s.Close(); $arc.Dispose();"
            r"     Write-Output 'COMPANION'; [Convert]::ToBase64String($ms.ToArray())"
            r"   } else { $arc.Dispose() }"
            r" } else {"
            r"   $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(),"
            r"           [IO.Path]::GetRandomFileName() + '.zip');"
            r"   Compress-Archive -LiteralPath $plain -DestinationPath $tmp -Force;"
            r"   Write-Output 'ZIPPED';"
            r"   [Convert]::ToBase64String([IO.File]::ReadAllBytes($tmp));"
            r"   Remove-Item $tmp -Force"
            r" }",
      ]);

      if (psResult.exitCode == 0) {
        final lines = (psResult.stdout as String).trimRight().split('\n');
        if (lines.length >= 2) {
          final marker = lines[0].trim();
          final b64 = lines.sublist(1).join('').trim();
          if (b64.isNotEmpty) {
            final bytes = base64Decode(b64);
            return marker == 'COMPANION'
                ? (displayName, bytes)
                : ('$displayName.zip', bytes);
          }
        }
      }
    } else {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final tempZip = '${Directory.systemTemp.path}/nm_$stamp.zip';
      final result = await Process.run(
        'zip', ['-r', tempZip, displayName],
        workingDirectory: Directory(path).parent.path,
      );
      if (result.exitCode == 0) {
        final bytes = await File(tempZip).readAsBytes();
        File(tempZip).delete().ignore();
        return ('$displayName.zip', bytes);
      }
    }

    throw Exception('Could not read directory: $path');
  }

  Future<Uint8List> _readDroppedFileBytes(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {}

    if (!Platform.isWindows) return File(path).readAsBytes();

    final winPath = r'\\?\' + path.replaceAll('/', r'\');
    final extEscaped = winPath.replaceAll("'", "''");
    final psResult = await Process.run('powershell', [
      '-NoProfile', '-NonInteractive', '-Command',
      "[Convert]::ToBase64String([IO.File]::ReadAllBytes('$extEscaped'))",
    ]);
    if (psResult.exitCode == 0) {
      final out = (psResult.stdout as String).trim();
      if (out.isNotEmpty) return base64Decode(out);
    }

    return File(path).readAsBytes();
  }

  String get _baseTitle => switch (widget.mode) {
        ComposeMode.newEmail => 'New Email',
        ComposeMode.reply => 'Reply',
        ComposeMode.replyAll => 'Reply All',
        ComposeMode.forward => 'Forward',
      };

  String get _title {
    final subject = _subjectController.text.trim();
    return subject.isNotEmpty ? subject : _baseTitle;
  }

  void _handleDrop(String address, String fromFieldId, String toFieldId) {
    if (fromFieldId == toFieldId) return;
    setState(() {
      if (fromFieldId == 'to') {
        _toRecipients = List.from(_toRecipients)..remove(address);
      } else {
        _ccRecipients = List.from(_ccRecipients)..remove(address);
      }
      if (toFieldId == 'to') {
        if (!_toRecipients.contains(address)) {
          _toRecipients = List.from(_toRecipients)..add(address);
        }
      } else {
        if (!_ccRecipients.contains(address)) {
          _ccRecipients = List.from(_ccRecipients)..add(address);
        }
      }
    });
  }

  Future<void> _submit(BuildContext context) async {
    _sent = true;
    _draftTimer?.cancel();
    _toFieldKey.currentState?.flush();
    _ccFieldKey.currentState?.flush();
    final to = _toRecipients;
    final cc = _ccRecipients;
    final subject = _subjectController.text.trim();

    if ((widget.mode == ComposeMode.newEmail ||
            widget.mode == ComposeMode.forward) &&
        to.isEmpty) {
      _sent = false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter at least one recipient')),
      );
      return;
    }

    final String effectiveBody;
    final EmailBodyType effectiveBodyType;

    if (_bodyType == EmailBodyType.html) {
      final freshHtml = await _htmlEditorKey.currentState?.getContent();
      if (freshHtml != null) _htmlBodyCache = freshHtml;
      effectiveBody = _substituteInlineImageSrcs(_htmlBodyCache);
      effectiveBodyType = EmailBodyType.html;

      if (_hasOrphanedInlineImages(effectiveBody)) {
        _sent = false;
        if (!mounted) return;
        final sendAnyway = await _confirmSendWithBrokenImages(context);
        if (sendAnyway != true) return;
        _sent = true;
      }
    } else {
      effectiveBody = _bodyController.text.trim();
      effectiveBodyType = EmailBodyType.text;
    }

    // The compose window is a separate process; windowManager.close() will kill
    // it as soon as ComposeSent fires. Delete the draft HERE, with await, so the
    // deletion completes before we dispatch (and before the process can be torn down).
    //
    // If _saveDraft() is still in-flight (timer already fired, HTTP pending),
    // wait for it via _saveCompleter so we get the ID it creates/returns.
    final inFlightId =
        _saveCompleter != null ? await _saveCompleter!.future : null;
    final idsToDelete = <String>{?_serverDraftId, ?inFlightId};
    _serverDraftId = null;
    if (idsToDelete.isNotEmpty) {
      await Future.wait(
        idsToDelete.map((id) async {
          try {
            await sl<DeleteServerDraft>()(id);
          } catch (_) {}
        }),
      );
      unawaited(_kDraftsRefreshChannel
          .invokeMethod<void>('notifyDraftChanged')
          .catchError((_) {}));
    }

    if (!mounted) return;
    context.read<ComposeBloc>().add(ComposeSubmitted(
          mode: widget.mode,
          originalMessageId: widget.originalEmail?.id,
          toAddresses: to,
          ccAddresses: cc,
          subject: subject,
          body: effectiveBody,
          excludedAttachmentIds: _excludedAttachmentIds,
          bodyType: effectiveBodyType,
          newAttachments: _localAttachments,
          fromAccountId: _selectedAccountId,
        ));
  }

  // True if the HTML references an inline image (cid:...) with no matching
  // local attachment — e.g. HTML pasted from another mail client that kept
  // the source's cid reference without the image bytes. Sending as-is bakes
  // a permanently broken image into the message.
  bool _hasOrphanedInlineImages(String html) {
    final knownCids = _localAttachments
        .where((a) => a.isInline && a.contentId != null)
        .map((a) => a.contentId!)
        .toSet();
    final matches = RegExp(r'<img\b[^>]*\bsrc="cid:([^"]+)"', caseSensitive: false)
        .allMatches(html);
    for (final match in matches) {
      final cid = match.group(1)!;
      if (!knownCids.contains(cid)) return true;
    }
    return false;
  }

  Future<bool?> _confirmSendWithBrokenImages(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: context.colors.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(
          'Broken Image in Message',
          style: TextStyle(
            color: context.colors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This message references an inline image that isn\'t attached — likely '
          'from content pasted in from another app. The recipient (and you, when '
          'viewing this later) will see a broken image icon instead.',
          style: TextStyle(color: context.colors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Go Back',
              style: TextStyle(color: context.colors.textMuted, fontSize: 13),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Send Anyway', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // Replace data: URI src attrs with cid: references for inline images.
  String _substituteInlineImageSrcs(String html) {
    return html.replaceAllMapped(
      RegExp(r'<img\b[^>]*>', caseSensitive: false),
      (match) {
        final tag = match.group(0)!;
        final cidMatch =
            RegExp(r'data-cid="([^"]*)"').firstMatch(tag);
        if (cidMatch == null) return tag;
        final contentId = cidMatch.group(1)!;
        return tag.replaceFirst(
          RegExp(r'src="data:[^"]*"'),
          'src="cid:$contentId"',
        );
      },
    );
  }

  Future<void> _pickAttachments() async {
    final picked = await openFiles();
    if (!mounted || picked.isEmpty) return;
    final attachments = await Future.wait(
      picked.map((f) async => LocalAttachment(
        path: f.path,
        name: f.name,
        mimeType: LocalAttachment.mimeTypeFromName(f.name),
        bytes: await f.readAsBytes(),
      )),
    );
    setState(() => _localAttachments = [..._localAttachments, ...attachments]);
    _scheduleDraftSave();
  }

  Future<void> _onLinkRequested(BuildContext context) async {
    final editorState = _htmlEditorKey.currentState;
    if (editorState != null) await editorState.hide();

    final url = await showInsertLinkDialog(context);

    if (mounted && editorState != null) await editorState.show();
    if (url != null && url.isNotEmpty) {
      _htmlEditorKey.currentState?.insertLink(url);
    }
  }

  List<Widget> _buildFields(AppColors c) => [
        _FromFieldRow(
          accounts: widget.accounts,
          selectedAccountId: _selectedAccountId,
          fallbackText: widget.fromAddress,
          onChanged: (id) => setState(() => _selectedAccountId = id),
        ),
        const SizedBox(height: 8),
        RecipientInputField(
          key: _toFieldKey,
          label: 'To',
          fieldId: 'to',
          recipients: _toRecipients,
          onChanged: (r) {
            setState(() => _toRecipients = r);
            _scheduleDraftSave();
          },
          onDropAccepted: (address, fromFieldId) =>
              _handleDrop(address, fromFieldId, 'to'),
          showInput: true,
          hintText: 'recipient@example.com',
          accountId: _selectedAccountId,
          accountDomain: _selectedAccountDomain,
          onTabToNext: () => _ccFieldKey.currentState?.requestFocus(),
        ),
        const SizedBox(height: 8),
        RecipientInputField(
          key: _ccFieldKey,
          label: 'Cc',
          fieldId: 'cc',
          recipients: _ccRecipients,
          onChanged: (r) {
            setState(() => _ccRecipients = r);
            _scheduleDraftSave();
          },
          onDropAccepted: (address, fromFieldId) =>
              _handleDrop(address, fromFieldId, 'cc'),
          showInput: true,
          hintText: 'cc@example.com',
          accountId: _selectedAccountId,
          accountDomain: _selectedAccountDomain,
          onTabToNext: () => _subjectFocus.requestFocus(),
        ),
        const SizedBox(height: 8),
        _FieldRow(
          label: 'Subject',
          controller: _subjectController,
          enabled: true,
          hintText: 'Subject',
          focusNode: _subjectFocus,
        ),
        const SizedBox(height: 12),
        Divider(height: 1, color: c.border),
        const SizedBox(height: 12),
      ];

  Widget _buildEditorModeRow(AppColors c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          const Spacer(),
          Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: c.surfaceBase,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<EmailBodyType>(
                value: _bodyType,
                isDense: true,
                dropdownColor: c.surfacePanel,
                style: TextStyle(color: c.textSecondary, fontSize: 11),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(
                    value: EmailBodyType.html,
                    child: Text('Rich Text'),
                  ),
                  DropdownMenuItem(
                    value: EmailBodyType.text,
                    child: Text('Plain Text'),
                  ),
                ],
                onChanged: (val) {
                  if (val == null || val == _bodyType) return;
                  if (val == EmailBodyType.text) {
                    _switchToPlainText(context);
                  } else {
                    _switchToHtml();
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBodyEditor(AppColors c) {
    if (_bodyType == EmailBodyType.html) {
      return HtmlEmailEditor(
        key: _htmlEditorKey,
        initialHtml: _htmlBodyCache,
        autofocus: widget.mode == ComposeMode.reply ||
            widget.mode == ComposeMode.replyAll,
        onContentChanged: (html) {
          _htmlBodyCache = html;
          _scheduleDraftSave();
        },
        onLinkRequested: () => _onLinkRequested(context),
        onAttachRequested: _pickAttachments,
      );
    }

    return TextField(
      controller: _bodyController,
      focusNode: _bodyFocus,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: TextStyle(
        color: c.textPrimary,
        fontSize: 13,
        height: 1.5,
      ),
      decoration: InputDecoration(
        hintText: 'Write your message here…',
        hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return BlocListener<ComposeBloc, ComposeState>(
      listenWhen: (_, curr) => curr is ComposeSent,
      listener: (_, _) { _deleteDraft(); },
      child: BlocListener<AiComposeCubit, AiComposeState>(
        bloc: _aiCubit,
        listener: _onAiComposeStateChanged,
        child: DropTarget(
          onDragDone: _addDroppedFiles,
          onDragEntered: (_) => setState(() => _isDragOver = true),
          onDragExited: (_) => setState(() => _isDragOver = false),
          child: _buildContent(context, c),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, AppColors c) {
    final forwardEmail =
        widget.mode == ComposeMode.forward ? widget.originalEmail : null;
    final visibleAttachments =
        _localAttachments.where((a) => !a.isInline).toList();

    if (widget.scrollable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(title: _title, onClose: () => _requestClose(context)),
          Divider(height: 1, color: c.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _buildFields(c),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (forwardEmail != null &&
                          forwardEmail.attachments.isNotEmpty)
                        _ForwardAttachmentChips(
                          attachments: forwardEmail.attachments,
                          excludedIds: _excludedAttachmentIds,
                          onRemove: (id) => setState(
                              () => _excludedAttachmentIds = [
                                    ..._excludedAttachmentIds,
                                    id
                                  ]),
                        ),
                      if (visibleAttachments.isNotEmpty)
                        _LocalAttachmentChips(
                          attachments: visibleAttachments,
                          onRemove: (att) => setState(() => _localAttachments =
                              _localAttachments.where((a) => a != att).toList()),
                        ),
                      Expanded(
                        flex: 2,
                        child: _buildBodyEditor(c),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                if (_isDragOver) const Positioned.fill(child: _DropOverlay()),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          _Footer(
            onSend: () => _submit(context),
            onClose: () => _requestClose(context),
            draftSavedAt: _lastDraftSavedAt,
            bodyType: _bodyType,
            onBodyTypeChanged: (val) {
              if (val == EmailBodyType.text) {
                _switchToPlainText(context);
              } else {
                _switchToHtml();
              }
            },
            onAiCompose:
                _aiGenerating ? null : () => _onAiCompose(context),
          ),
        ],
      );
    }

    return SizedBox(
      width: 600,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(title: _title, onClose: () => _requestClose(context)),
          Divider(height: 1, color: c.border),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ..._buildFields(c),
                if (forwardEmail != null && forwardEmail.attachments.isNotEmpty)
                  _ForwardAttachmentChips(
                    attachments: forwardEmail.attachments,
                    excludedIds: _excludedAttachmentIds,
                    onRemove: (id) => setState(
                        () => _excludedAttachmentIds = [..._excludedAttachmentIds, id]),
                  ),
                if (visibleAttachments.isNotEmpty)
                  _LocalAttachmentChips(
                    attachments: visibleAttachments,
                    onRemove: (att) => setState(() => _localAttachments =
                        _localAttachments.where((a) => a != att).toList()),
                  ),
                Stack(
                  children: [
                    SizedBox(
                      height: forwardEmail != null ? 150 : 240,
                      child: _buildBodyEditor(c),
                    ),
                    if (_isDragOver) const Positioned.fill(child: _DropOverlay()),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          _Footer(
            onSend: () => _submit(context),
            onClose: () => _requestClose(context),
            draftSavedAt: _lastDraftSavedAt,
            bodyType: _bodyType,
            onBodyTypeChanged: (val) {
              if (val == EmailBodyType.text) {
                _switchToPlainText(context);
              } else {
                _switchToHtml();
              }
            },
            onAiCompose:
                _aiGenerating ? null : () => _onAiCompose(context),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _stripHtml(String html) {
  return html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<div[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</div>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _plainToHtml(String text) {
  if (text.isEmpty) return '';
  final escape = const HtmlEscape();
  return text.split('\n').map((line) {
    final escaped = escape.convert(line);
    return escaped.isEmpty ? '<div><br></div>' : '<div>$escaped</div>';
  }).join('');
}

String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  const months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  const days = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final h = local.hour;
  final min = local.minute.toString().padLeft(2, '0');
  final amPm = h >= 12 ? 'PM' : 'AM';
  final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
  return '${days[local.weekday]}, ${months[local.month]} ${local.day}, '
      '${local.year} at $h12:$min $amPm';
}

// ---------------------------------------------------------------------------
// Supporting widgets
// ---------------------------------------------------------------------------

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.title, required this.onClose});
  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: c.textMuted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _FromFieldRow extends StatelessWidget {
  const _FromFieldRow({
    required this.accounts,
    required this.selectedAccountId,
    required this.fallbackText,
    required this.onChanged,
  });

  final List<Account> accounts;
  final String? selectedAccountId;
  final String fallbackText;
  final ValueChanged<String?> onChanged;

  static String _labelFor(Account a) => a.senderName.isNotEmpty
      ? '${a.senderName} <${a.emailAddress}>'
      : a.emailAddress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = Padding(
      padding: const EdgeInsets.only(top: 2),
      child: SizedBox(
        width: 52,
        child: Text(
          'From',
          style: TextStyle(
            color: c.textDimmed,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );

    if (accounts.length <= 1) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          Expanded(
            child: Text(
              accounts.isNotEmpty ? _labelFor(accounts.first) : fallbackText,
              style: TextStyle(color: c.textTertiary, fontSize: 13),
            ),
          ),
        ],
      );
    }

    final value =
        accounts.any((a) => a.id == selectedAccountId) ? selectedAccountId : accounts.first.id;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label,
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isDense: true,
              isExpanded: true,
              dropdownColor: c.surfacePanel,
              style: TextStyle(color: c.textPrimary, fontSize: 13),
              items: accounts
                  .map((a) => DropdownMenuItem(
                        value: a.id,
                        child: Text(_labelFor(a), overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.controller,
    required this.enabled,
    required this.hintText,
    this.focusNode,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final String hintText;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: SizedBox(
            width: 52,
            child: Text(
              label,
              style: TextStyle(
                color: c.textDimmed,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            focusNode: focusNode,
            maxLines: null,
            style: TextStyle(
              color: enabled ? c.textPrimary : c.textTertiary,
              fontSize: 13,
            ),
            decoration: InputDecoration(
              hintText: enabled ? hintText : null,
              hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }
}

class _ForwardAttachmentChips extends StatelessWidget {
  const _ForwardAttachmentChips({
    required this.attachments,
    required this.excludedIds,
    required this.onRemove,
  });

  final List<EmailAttachment> attachments;
  final List<String> excludedIds;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final visible =
        attachments.where((a) => !excludedIds.contains(a.id)).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: visible
            .map((att) => _AttachmentChip(
                  attachment: att,
                  onRemove: () => onRemove(att.id),
                ))
            .toList(),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment, required this.onRemove});

  final EmailAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceBase,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file, size: 12, color: c.textMuted),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              attachment.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.textPrimary),
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close, size: 12, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

enum _CloseAction { saveToDrafts, delete }

class _CloseDraftDialog extends StatelessWidget {
  const _CloseDraftDialog();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: Text(
        'Save draft?',
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Text(
        'Would you like to save this email as a draft or discard it?',
        style: TextStyle(color: c.textSecondary, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_CloseAction.delete),
          child: Text(
            'Delete',
            style: TextStyle(color: Colors.red.shade400, fontSize: 13),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Keep editing',
            style: TextStyle(color: c.textMuted, fontSize: 13),
          ),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_CloseAction.saveToDrafts),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Save to Drafts', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

class _LocalAttachmentChips extends StatelessWidget {
  const _LocalAttachmentChips({
    required this.attachments,
    required this.onRemove,
  });

  final List<LocalAttachment> attachments;
  final ValueChanged<LocalAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: attachments
            .map((att) => Container(
                  decoration: BoxDecoration(
                    color: c.surfaceBase,
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.attach_file, size: 12, color: c.textMuted),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: Text(
                          att.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: c.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        onTap: () => onRemove(att),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child:
                              Icon(Icons.close, size: 12, color: c.textMuted),
                        ),
                      ),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.accent, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.attach_file_rounded, size: 40, color: AppColors.accent),
            SizedBox(height: 8),
            Text(
              'Drop files to attach',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatefulWidget {
  const _Footer({
    required this.onSend,
    required this.onClose,
    this.draftSavedAt,
    required this.bodyType,
    required this.onBodyTypeChanged,
    this.onAiCompose,
  });
  final VoidCallback onSend;
  final VoidCallback onClose;
  final DateTime? draftSavedAt;
  final EmailBodyType bodyType;
  final ValueChanged<EmailBodyType> onBodyTypeChanged;
  // Opens the AI draft prompt. Null while a generation is already in flight.
  final VoidCallback? onAiCompose;

  @override
  State<_Footer> createState() => _FooterState();
}

class _FooterState extends State<_Footer> with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;
  StreamSubscription<ComposeState>? _sub;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub?.cancel();
    final bloc = context.read<ComposeBloc>();
    _syncShimmer(bloc.state);
    _sub = bloc.stream.listen(_syncShimmer);
  }

  void _syncShimmer(ComposeState state) {
    if (state is ComposeSending) {
      _shimmer.repeat();
    } else {
      _shimmer.stop();
      _shimmer.reset();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<ComposeBloc, ComposeState>(
      builder: (context, state) {
        final isSending = state is ComposeSending;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: c.surfaceBase,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: c.border),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<EmailBodyType>(
                    value: widget.bodyType,
                    isDense: true,
                    dropdownColor: c.surfacePanel,
                    style: TextStyle(color: c.textSecondary, fontSize: 11),
                    items: const [
                      DropdownMenuItem(
                        value: EmailBodyType.html,
                        child: Text('Rich Text'),
                      ),
                      DropdownMenuItem(
                        value: EmailBodyType.text,
                        child: Text('Plain Text'),
                      ),
                    ],
                    onChanged: isSending
                        ? null
                        : (val) {
                            if (val != null) widget.onBodyTypeChanged(val);
                          },
                  ),
                ),
              ),
              if (widget.draftSavedAt != null) ...[
                const SizedBox(width: 8),
                Text(
                  'Draft saved',
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                ),
              ],
              const Spacer(),
              TextButton.icon(
                onPressed: isSending ? null : widget.onAiCompose,
                icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                label: const Text('AI', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: isSending ? null : widget.onClose,
                child: Text(
                  'Cancel',
                  style: TextStyle(color: c.textMuted, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              if (isSending)
                AnimatedBuilder(
                  animation: _shimmer,
                  builder: (context, child) {
                    final t = _shimmer.value;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment(-2 + t * 4, 0),
                          end: Alignment(-1 + t * 4, 0),
                          colors: [
                            AppColors.accent,
                            Colors.white.withValues(alpha: 0.30),
                            AppColors.accent,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: child,
                    );
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.send_rounded, size: 14, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        'Sending…',
                        style: TextStyle(fontSize: 13, color: Colors.white),
                      ),
                    ],
                  ),
                )
              else
                FilledButton.icon(
                  onPressed: widget.onSend,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.send_rounded, size: 14),
                  label: const Text(
                    'Send',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
