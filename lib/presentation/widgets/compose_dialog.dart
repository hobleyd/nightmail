import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../injection_container.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_attachment.dart';
import '../../domain/entities/local_attachment.dart';
import '../../domain/usecases/delete_server_draft.dart';
import '../../domain/usecases/save_server_draft.dart';
import '../../domain/usecases/send_email.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/compose/compose_bloc.dart';
import '../blocs/compose/compose_event.dart';
import '../blocs/compose/compose_state.dart';
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
  });

  final ComposeMode mode;
  final Email? originalEmail;
  final Email? draftEmail;
  final String fromAddress;
  final String? accountId;
  final String? accountDomain;

  static Future<void> show(
    BuildContext context, {
    required ComposeMode mode,
    Email? originalEmail,
    Email? draftEmail,
  }) {
    final accountState = context.read<AccountCubit>().state;
    final fromAddress = accountState is AccountsLoaded
        ? () {
            final account = accountState.activeAccount;
            final name = account.displayName;
            final email = account.emailAddress;
            return name.isNotEmpty ? '$name <$email>' : email;
          }()
        : '';
    final accountId =
        accountState is AccountsLoaded ? accountState.activeAccount.id : null;
    final accountDomain = accountState is AccountsLoaded
        ? _domainOf(accountState.activeAccount.emailAddress)
        : null;
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
    this.scrollable = false,
    this.existingDraftId,
    this.onTitleChanged,
  });

  final ComposeMode mode;
  final Email? originalEmail;
  // When set, pre-populates all fields from a saved draft (server-side or local).
  final Email? draftEmail;
  final VoidCallback onClose;
  final String fromAddress;
  final String? accountId;
  final String? accountDomain;
  final bool scrollable;
  // Server-side ID of the draft being edited. When provided, the first
  // successful auto-save updates this draft (Graph/IMAP) then deletes it,
  // replacing it with a fresh one so the ID stays current.
  final String? existingDraftId;
  final ValueChanged<String>? onTitleChanged;

  @override
  State<ComposeForm> createState() => _ComposeFormState();
}

class _ComposeFormState extends State<ComposeForm> {
  late List<String> _toRecipients;
  late List<String> _ccRecipients;
  final _toFieldKey = GlobalKey<RecipientInputFieldState>();
  final _ccFieldKey = GlobalKey<RecipientInputFieldState>();
  late final TextEditingController _fromController;
  late final TextEditingController _subjectController;
  late final TextEditingController _bodyController;
  final FocusNode _bodyFocus = FocusNode();
  List<String> _excludedAttachmentIds = [];
  List<LocalAttachment> _localAttachments = [];
  bool _isDragOver = false;

  String? _serverDraftId;
  // Set when opened from an existing server draft. After the first successful
  // save the old draft is deleted and this is cleared.
  String? _pendingOldDraftId;
  Timer? _draftTimer;
  DateTime? _lastDraftSavedAt;

  @override
  void initState() {
    super.initState();
    _toRecipients = _parseAddresses(_initialTo());
    _ccRecipients = _parseAddresses(_initialCc());
    _fromController = TextEditingController(text: widget.fromAddress);
    _subjectController = TextEditingController(text: _initialSubject());
    _bodyController = TextEditingController(text: _initialBody());
    _subjectController.addListener(_onSubjectChanged);
    _bodyController.addListener(_scheduleDraftSave);
    // When opening an existing server draft, seed the ID so the first
    // auto-save updates it rather than creating a duplicate.
    _serverDraftId = widget.existingDraftId;
    _pendingOldDraftId = widget.existingDraftId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final isReply = widget.mode == ComposeMode.reply ||
          widget.mode == ComposeMode.replyAll;
      if (isReply) {
        _bodyFocus.requestFocus();
        _bodyController.selection = const TextSelection.collapsed(offset: 0);
      } else {
        _toFieldKey.currentState?.requestFocus();
      }
      widget.onTitleChanged?.call(_title);
    });
  }

  static const _forwardSeparator = '---------- Forwarded message ---------';

  String _initialBody() {
    if (widget.draftEmail != null) return widget.draftEmail!.body;
    final email = widget.originalEmail;
    if (email == null) return '';

    final fromName = email.from.name;
    final from = (fromName != null && fromName.isNotEmpty)
        ? '$fromName <${email.from.address}>'
        : email.from.address;

    if (widget.mode == ComposeMode.forward) {
      final bodyText = email.bodyType == EmailBodyType.html
          ? _stripHtml(email.body)
          : email.body;
      return '\n\n$_forwardSeparator\n'
          'From: $from\n'
          'Date: ${_formatDate(email.receivedDateTime)}\n'
          'Subject: ${email.subject}\n\n'
          '$bodyText';
    }

    if (widget.mode != ComposeMode.reply && widget.mode != ComposeMode.replyAll) {
      return '';
    }

    final header = 'On ${_formatDate(email.receivedDateTime)}, $from wrote:';
    if (email.bodyType == EmailBodyType.html) {
      final bodyText = _stripHtml(email.body);
      return '\n\n---\n\n$header\n\n$bodyText';
    } else {
      final quoted = email.body
          .split('\n')
          .map((line) => '> $line')
          .join('\n');
      return '\n\n$header\n$quoted';
    }
  }

  List<String> _parseAddresses(String text) {
    if (text.trim().isEmpty) return [];
    return text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }

  // Extracts the bare email address from a string that may be "Name <addr>" or just "addr".
  String _bareAddress(String address) {
    final match = RegExp(r'<([^>]+)>').firstMatch(address);
    return (match?.group(1) ?? address).trim();
  }

  String _initialTo() {
    if (widget.draftEmail != null) {
      return widget.draftEmail!.toRecipients.map((r) => r.address).join(', ');
    }
    final email = widget.originalEmail;
    if (email == null) return '';
    return switch (widget.mode) {
      ComposeMode.reply => email.from.address,
      ComposeMode.replyAll => [
          email.from.address,
          ...email.toRecipients.map((r) => r.address),
        ].where((a) => a.toLowerCase() != _bareAddress(widget.fromAddress).toLowerCase()).join(', '),
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
      ComposeMode.replyAll =>
        email.ccRecipients.map((r) => r.address).where((a) => a.toLowerCase() != _bareAddress(widget.fromAddress).toLowerCase()).join(', '),
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
    // Capture values before controllers are torn down.
    final hasPendingSave = _draftTimer?.isActive == true;
    final draftId = _serverDraftId;
    final oldDraftId = _pendingOldDraftId;
    final to = List<String>.from(_toRecipients);
    final cc = List<String>.from(_ccRecipients);
    final subject = _subjectController.text;
    final body = _bodyController.text;
    final attachments = List<LocalAttachment>.from(_localAttachments);

    _draftTimer?.cancel();
    _subjectController.removeListener(_onSubjectChanged);
    _bodyController.removeListener(_scheduleDraftSave);
    _fromController.dispose();
    _subjectController.dispose();
    _bodyController.dispose();
    _bodyFocus.dispose();
    super.dispose();

    // If a debounced save was queued when the window closed, flush it now.
    if (hasPendingSave) {
      sl<SaveServerDraft>()(SaveServerDraftParams(
        existingDraftId: draftId,
        toAddresses: to,
        ccAddresses: cc,
        subject: subject,
        body: body,
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

  // Returns null on success, or an error message string on failure.
  Future<String?> _saveDraft() async {
    final oldDraftId = _pendingOldDraftId;
    final result = await sl<SaveServerDraft>()(SaveServerDraftParams(
      existingDraftId: _serverDraftId,
      toAddresses: _toRecipients,
      ccAddresses: _ccRecipients,
      subject: _subjectController.text,
      body: _bodyController.text,
      newAttachments: _localAttachments,
    ));
    return result.fold(
      (failure) => failure.message,
      (newId) {
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
  }

  Future<void> _deleteDraft() async {
    if (_serverDraftId == null) return;
    await sl<DeleteServerDraft>()(_serverDraftId!);
    _serverDraftId = null;
  }

  bool get _hasContent =>
      _serverDraftId != null ||
      _toRecipients.isNotEmpty ||
      _ccRecipients.isNotEmpty ||
      _subjectController.text.isNotEmpty ||
      _bodyController.text.isNotEmpty ||
      _localAttachments.isNotEmpty;

  Future<void> _requestClose(BuildContext context) async {
    if (!_hasContent) {
      widget.onClose();
      return;
    }

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
        if (mounted) widget.onClose();
      case null:
        // dismissed — keep editing
        break;
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
        ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(
          content: Text(failCount == 1
              ? 'Could not attach file: Windows denied access. Try copying it to your Desktop first.'
              : '$failCount files could not be attached: Windows denied access.'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 8),
        ));
      }
      if (added.isNotEmpty) {
        setState(() => _localAttachments = [..._localAttachments, ...added]);
        _scheduleDraftSave();
      }
    });
  }

  // Returns (attachmentName, bytes) for a dropped directory.
  //
  // If a companion .zip exists at path + '.zip' (the tell-tale sign that Win32
  // path-normalisation turned a filename like "report .pdf" into a directory),
  // we extract the largest entry from that .zip and keep the original name.
  // Otherwise we treat the drop as a genuine folder and compress it to a .zip.
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
      // macOS / Linux: zip via the system zip command.
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

    // .NET honours \\?\ without path normalisation, letting us open files whose
    // names contain a trailing space before the extension.
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

  bool get _toInputEditable => true;

  bool get _ccInputEditable => true;

  bool get _subjectEditable => true;

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

  void _submit(BuildContext context) {
    _toFieldKey.currentState?.flush();
    _ccFieldKey.currentState?.flush();
    final to = _toRecipients;
    final cc = _ccRecipients;
    final subject = _subjectController.text.trim();
    final body = _bodyController.text.trim();

    if ((widget.mode == ComposeMode.newEmail ||
            widget.mode == ComposeMode.forward) &&
        to.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter at least one recipient')),
      );
      return;
    }

    final originalBodyType =
        widget.originalEmail?.bodyType ?? EmailBodyType.text;
    final isReplyLike = widget.mode == ComposeMode.reply ||
        widget.mode == ComposeMode.replyAll;

    final String effectiveBody;
    if (isReplyLike && originalBodyType == EmailBodyType.html) {
      // For HTML originals, convert the plain-text body field to HTML so the
      // sent message matches the original email's content type.
      effectiveBody = const HtmlEscape().convert(body).replaceAll('\n', '<br>');
    } else {
      effectiveBody = body;
    }

    // Forward always sends plain text — _initialBody() strips HTML when
    // pre-populating, so the compose body is always plain regardless of original.
    final effectiveBodyType = widget.mode == ComposeMode.forward
        ? EmailBodyType.text
        : (isReplyLike && originalBodyType == EmailBodyType.html)
            ? EmailBodyType.html
            : originalBodyType;

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
        ));
  }

  List<Widget> _buildFields(AppColors c, String? accountId) => [
        _FieldRow(
          label: 'From',
          controller: _fromController,
          enabled: false,
          hintText: '',
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
          showInput: _toInputEditable,
          hintText: 'recipient@example.com',
          accountId: accountId,
          accountDomain: widget.accountDomain,
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
          showInput: _ccInputEditable,
          hintText: 'cc@example.com',
          accountId: accountId,
          accountDomain: widget.accountDomain,
        ),
        const SizedBox(height: 8),
        _FieldRow(
          label: 'Subject',
          controller: _subjectController,
          enabled: _subjectEditable,
          hintText: 'Subject',
        ),
        const SizedBox(height: 12),
        Divider(height: 1, color: c.border),
        const SizedBox(height: 12),
      ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accountId = widget.accountId;

    return BlocListener<ComposeBloc, ComposeState>(
      listenWhen: (_, curr) => curr is ComposeSent,
      listener: (_, _) { _deleteDraft(); },
      child: DropTarget(
        onDragDone: _addDroppedFiles,
        onDragEntered: (_) => setState(() => _isDragOver = true),
        onDragExited: (_) => setState(() => _isDragOver = false),
        child: _buildContent(context, c, accountId),
      ),
    );
  }

  Widget _buildContent(BuildContext context, AppColors c, String? accountId) {
    if (widget.scrollable) {
      final forwardEmail =
          widget.mode == ComposeMode.forward ? widget.originalEmail : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(title: _title, onClose: () => _requestClose(context)),
          Divider(height: 1, color: c.border),
          // Fields are fixed-height — kept outside the Expanded area so the
          // body + quoted-email section can grow freely when the window resizes.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _buildFields(c, accountId),
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
                      if (_localAttachments.isNotEmpty)
                        _LocalAttachmentChips(
                          attachments: _localAttachments,
                          onRemove: (att) => setState(() => _localAttachments =
                              _localAttachments.where((a) => a != att).toList()),
                        ),
                      Expanded(
                        flex: 2,
                        child: TextField(
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
                            hintStyle:
                                TextStyle(color: c.textMuted, fontSize: 13),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
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
          _Footer(onSend: () => _submit(context), onClose: () => _requestClose(context), draftSavedAt: _lastDraftSavedAt),
        ],
      );
    }

    final forwardEmail =
        widget.mode == ComposeMode.forward ? widget.originalEmail : null;
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
                ..._buildFields(c, accountId),
                if (forwardEmail != null &&
                    forwardEmail.attachments.isNotEmpty)
                  _ForwardAttachmentChips(
                    attachments: forwardEmail.attachments,
                    excludedIds: _excludedAttachmentIds,
                    onRemove: (id) => setState(
                        () => _excludedAttachmentIds = [..._excludedAttachmentIds, id]),
                  ),
                if (_localAttachments.isNotEmpty)
                  _LocalAttachmentChips(
                    attachments: _localAttachments,
                    onRemove: (att) => setState(() => _localAttachments =
                        _localAttachments.where((a) => a != att).toList()),
                  ),
                Stack(
                  children: [
                    SizedBox(
                      height: forwardEmail != null ? 150 : 240,
                      child: TextField(
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
                      ),
                    ),
                    if (_isDragOver) const Positioned.fill(child: _DropOverlay()),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          _Footer(onSend: () => _submit(context), onClose: () => _requestClose(context), draftSavedAt: _lastDraftSavedAt),
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

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.controller,
    required this.enabled,
    required this.hintText,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final String hintText;

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

class _Footer extends StatelessWidget {
  const _Footer({required this.onSend, required this.onClose, this.draftSavedAt});
  final VoidCallback onSend;
  final VoidCallback onClose;
  final DateTime? draftSavedAt;

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
              if (draftSavedAt != null)
                Text(
                  'Draft saved',
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                ),
              const Spacer(),
              TextButton(
                onPressed: isSending ? null : onClose,
                child: Text(
                  'Cancel',
                  style: TextStyle(color: c.textMuted, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: isSending ? null : onSend,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: isSending
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded, size: 14),
                label: Text(
                  isSending ? 'Sending…' : 'Send',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
