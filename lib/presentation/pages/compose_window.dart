import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/platform/window_utils.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/window_bounds_service.dart';
import '../../core/signature/signature_merge_engine.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/mailto_parser.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_address.dart';
import '../../domain/entities/email_attachment.dart';
import '../../domain/entities/inline_attachment.dart';
import '../../domain/usecases/send_email.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';
import '../blocs/compose/compose_bloc.dart';
import '../blocs/compose/compose_state.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';
import '../widgets/compose_dialog.dart';
import '../widgets/error_snack_bar.dart';

class ComposeWindowApp extends StatelessWidget {
  const ComposeWindowApp({
    super.key,
    required this.windowId,
    required this.arguments,
  });

  final String windowId;
  final Map<String, dynamic> arguments;

  /// Opens a compose screen prefilled from a `mailto:` URI (RFC 6068).
  ///
  /// Both ways of arriving at one land here: another application handing the
  /// URI to the OS, which starts or raises NightMail as the registered handler,
  /// and a `mailto:` link the reader clicked inside a message — see
  /// `openBodyLink`, which deliberately does not send that one back out to the
  /// OS only to be handed straight back.
  ///
  /// A `bcc` parameter is dropped, because nothing downstream of here — neither
  /// [Email] nor the compose form — carries a BCC list yet.
  static Future<void> openMailto(BuildContext context, Uri uri) {
    final data = MailtoParser.parse(uri);
    return open(
      context,
      mode: ComposeMode.newEmail,
      draftEmail: Email(
        id: '',
        subject: data.subject,
        from: const EmailAddress(address: ''),
        toRecipients:
            data.to.map((a) => EmailAddress(address: a)).toList(),
        ccRecipients:
            data.cc.map((a) => EmailAddress(address: a)).toList(),
        bodyPreview: '',
        body: data.body,
        bodyType: EmailBodyType.text,
        isRead: false,
        receivedDateTime: DateTime.now(),
        importance: EmailImportance.normal,
      ),
    );
  }

  /// Opens a compose screen: a new push route on mobile, a sub-window on desktop.
  static Future<void> open(
    BuildContext context, {
    required ComposeMode mode,
    Email? originalEmail,
    Email? draftEmail,
    String? existingDraftId,
    VoidCallback? onSent,
  }) async {
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    if (isMobile) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _MobileComposePage(
            mode: mode,
            originalEmail: originalEmail,
            draftEmail: draftEmail,
            existingDraftId: existingDraftId,
            onSent: onSent,
          ),
          fullscreenDialog: true,
        ),
      );
      return;
    }

    Map<String, dynamic> args = {'mode': mode.name};
    if (existingDraftId != null) args['existingDraftId'] = existingDraftId;
    if (originalEmail != null) {
      args['originalEmail'] = {
        'id': originalEmail.id,
        'subject': originalEmail.subject,
        'from': {
          'address': originalEmail.from.address,
          'name': originalEmail.from.name,
        },
        'toRecipients': originalEmail.toRecipients
            .map((r) => {'address': r.address, 'name': r.name})
            .toList(),
        'ccRecipients': originalEmail.ccRecipients
            .map((r) => {'address': r.address, 'name': r.name})
            .toList(),
        'body': originalEmail.body,
        'bodyType': originalEmail.bodyType.name,
        'receivedDateTime': originalEmail.receivedDateTime.toIso8601String(),
        'attachments': originalEmail.attachments
            .map((a) => {
                  'id': a.id,
                  'name': a.name,
                  'contentType': a.contentType,
                  'size': a.size,
                })
            .toList(),
        'inlineAttachments':
            _inlineAttachmentsToJson(originalEmail.inlineAttachments),
      };
    }
    if (draftEmail != null) {
      args['draftEmail'] = {
        'subject': draftEmail.subject,
        'toRecipients': draftEmail.toRecipients
            .map((r) => {'address': r.address, 'name': r.name})
            .toList(),
        'ccRecipients': draftEmail.ccRecipients
            .map((r) => {'address': r.address, 'name': r.name})
            .toList(),
        'body': draftEmail.body,
        'bodyType': draftEmail.bodyType.name,
        'inlineAttachments':
            _inlineAttachmentsToJson(draftEmail.inlineAttachments),
      };
    }
    await createSubWindow(
      WindowConfiguration(arguments: jsonEncode(args)),
    );
  }

  /// Inline images have to cross the window boundary as bytes: the sub-window
  /// runs its own engine, and the quoted body it builds references them by
  /// `cid:`, which nothing downstream of here can resolve on its own.
  ///
  /// The whole argument map is JSON-encoded into a single string and handed to
  /// the platform channel, so a message carrying tens of megabytes of embedded
  /// images would stall window creation. Fill greedily up to a budget instead
  /// and let the remainder stay unresolved — the same broken-image result as
  /// before, but only for the images past the cap.
  static const int _maxInlineAttachmentBytes = 12 * 1024 * 1024;

  static List<Map<String, dynamic>> _inlineAttachmentsToJson(
    List<InlineAttachment> attachments,
  ) {
    final out = <Map<String, dynamic>>[];
    var budget = _maxInlineAttachmentBytes;
    for (final a in attachments) {
      if (a.contentBytes.length > budget) continue;
      budget -= a.contentBytes.length;
      out.add({
        'contentId': a.contentId,
        'contentType': a.contentType,
        'contentBytes': base64.encode(a.contentBytes),
      });
    }
    return out;
  }

  static List<InlineAttachment> _inlineAttachmentsFromJson(dynamic raw) {
    if (raw is! List) return const [];
    final out = <InlineAttachment>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final contentId = entry['contentId'] as String?;
      final bytes = entry['contentBytes'] as String?;
      if (contentId == null || contentId.isEmpty || bytes == null) continue;
      try {
        out.add(InlineAttachment(
          contentId: contentId,
          contentType: entry['contentType'] as String? ?? 'application/octet-stream',
          contentBytes: base64.decode(bytes),
        ));
      } catch (_) {
        // Malformed payload — skip it rather than fail the whole window.
      }
    }
    return out;
  }

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
    return BlocProvider<ThemeCubit>(
      create: (_) => sl<ThemeCubit>()..load(),
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: switch (themeState.mode) {
              AppThemeMode.light => ThemeMode.light,
              AppThemeMode.dark => ThemeMode.dark,
              AppThemeMode.system => ThemeMode.system,
            },
            home: _ComposeWindowPage(
              windowId: windowId,
              mode: ComposeMode.values.byName(
                arguments['mode'] as String? ?? 'newEmail',
              ),
              arguments: arguments,
            ),
          );
        },
      ),
    );
  }
}

class _ComposeWindowPage extends StatefulWidget {
  const _ComposeWindowPage({
    required this.windowId,
    required this.mode,
    required this.arguments,
  });

  final String windowId;
  final ComposeMode mode;
  final Map<String, dynamic> arguments;

  @override
  State<_ComposeWindowPage> createState() => _ComposeWindowPageState();
}

class _ComposeWindowPageState extends State<_ComposeWindowPage>
    with WindowListener {
  EmailBodyType _defaultComposeFormat = AppSettings.defaultComposeFormat;
  String _signatureHtml = '';

  // Lets [onWindowClose] reach the same save-or-discard prompt the Cancel
  // button runs.
  final _formKey = GlobalKey<ComposeFormState>();

  // Set once the prompt has been answered (or there was nothing to save), so
  // the close that _close() then asks for isn't mistaken for a fresh one.
  bool _closing = false;

  // Where the next compose window opens. `main()` restores this before the
  // window is shown; from here on the window records every move and resize.
  Timer? _boundsDebounce;
  Timer? _suppressBoundsSaveTimer;

  // Suppress saves triggered by the compositor repositioning the window during
  // startup (Linux/Wayland places a window after it is mapped, firing
  // onWindowMove before the user has touched anything).
  bool _suppressBoundsSave = Platform.isLinux;

  @override
  void initState() {
    super.initState();
    // The title-bar close button destroys the window without running dispose,
    // so intercept it and route it through the same prompt as Cancel. Both
    // window_manager and desktop_multi_window resolve the *calling engine's*
    // window, so this only holds the compose window, not the app.
    windowManager.addListener(this);
    windowManager.setPreventClose(true).catchError((_) {});
    if (_suppressBoundsSave) {
      _suppressBoundsSaveTimer =
          Timer(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        _suppressBoundsSave = false;
        // Record the position the compositor settled on, which may not be the
        // one that was asked for — otherwise the next window opens at bounds
        // Wayland has already refused once.
        _scheduleBoundsSave();
      });
    }
    sl<AppSettings>().loadDefaultComposeFormat().then((format) {
      if (mounted) setState(() => _defaultComposeFormat = format);
    });
    final signatureAccount = sl<AccountManager>().activeAccount;
    if (signatureAccount != null) {
      _signatureHtml = SignatureMergeEngine.merge(
          signatureAccount.signatureHtml, signatureAccount);
    }
    // The compose window is a separate engine. If the account email wasn't
    // persisted (legacy migration), backfill it now and rebuild once done.
    final account = sl<AccountManager>().activeAccount;
    if (account != null && account.emailAddress.isEmpty) {
      sl<AccountManager>().ensureEmailPopulated().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _boundsDebounce?.cancel();
    _suppressBoundsSaveTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  // ── Window geometry ──────────────────────────────────────────────────────
  //
  // The same debounce-and-save the main window uses, against its own file
  // (`composeWindowBounds`), so a compose window opens where the last one was
  // left rather than centred on the parent every time. Linux fires
  // resize/move continuously, which is what the debounce is for.

  void _scheduleBoundsSave() {
    if (_suppressBoundsSave) return;
    _boundsDebounce?.cancel();
    _boundsDebounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        // Maximize / full-screen have their own overrides below; saving plain
        // bounds here would record the maximized rect as a normal one.
        if (await windowManager.isMaximized()) return;
        if (await windowManager.isFullScreen()) return;
        await composeWindowBounds.saveBounds(await windowManager.getBounds());
      } catch (_) {}
    });
  }

  Future<void> _saveCurrentState() async {
    try {
      final fullScreen = await windowManager.isFullScreen();
      final maximized = await windowManager.isMaximized();
      await composeWindowBounds.saveBounds(
        await windowManager.getBounds(),
        fullScreen: fullScreen,
        maximized: maximized,
      );
    } catch (_) {}
  }

  // macOS/Windows: fires once when the resize/move finishes.
  @override
  void onWindowResized() => _scheduleBoundsSave();

  @override
  void onWindowMoved() => _scheduleBoundsSave();

  // Linux: fires continuously during a resize/move — the debounce handles it.
  @override
  void onWindowResize() => _scheduleBoundsSave();

  @override
  void onWindowMove() => _scheduleBoundsSave();

  // Save at once on entering a special state, so a close straight afterwards
  // doesn't have to re-query a window that is already going away.
  @override
  void onWindowMaximize() => _saveCurrentState();

  @override
  void onWindowEnterFullScreen() => _saveCurrentState();

  /// The title-bar close button. `setPreventClose` has already turned the OS
  /// close into an event, so ask the form what to do with the draft first and
  /// only then let the window go.
  ///
  /// If the form isn't mounted there is nothing to save, so close immediately —
  /// leaving the window un-closable would be worse than losing an empty draft.
  @override
  void onWindowClose() {
    if (_closing) return;
    final form = _formKey.currentState;
    if (form == null) {
      _close();
      return;
    }
    form.requestClose();
  }

  /// `windowManager.destroy()` is not an option here: on macOS it is
  /// `NSApp.terminate` and on Windows `PostQuitMessage`, either of which would
  /// take the whole app down with the compose window. Drop the guard instead
  /// and let the ordinary close proceed.
  ///
  /// **A close request is not an answer.** `windowManager.close()` *posts* a
  /// message to the window (`WM_SYSCOMMAND`/`SC_CLOSE` on Windows, an
  /// `NSWindow` performClose on macOS) and reports success as soon as it has
  /// been handed over — nothing tells us the window acted on it. A request that
  /// goes nowhere used to leave the worst possible state behind: the window
  /// still on screen, its close interception already switched off, and
  /// [_closing] latched so [onWindowClose] ignored the title-bar X — which then
  /// closed the window natively, discarding the draft with no prompt.
  ///
  /// So ask again, and if the window is still here after that, put the
  /// interception back and say so. A close that *did* take tears this engine
  /// down inside the wait, so reaching the line after it is itself the evidence
  /// that the window ignored us.
  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    // Closing this window is what tears the engine down, so a pending
    // debounced save would never fire — record the final geometry now instead.
    // Timed out rather than merely try/caught: nothing about remembering where
    // the window was is worth holding up a close the user asked for.
    _boundsDebounce?.cancel();
    try {
      await _saveCurrentState().timeout(const Duration(seconds: 1));
    } catch (_) {}
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await windowManager.setPreventClose(false);
        await windowManager.close();
      } catch (e) {
        debugPrint('[Compose] close attempt $attempt failed: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    debugPrint('[Compose] window ignored 3 close requests; restoring the guard');
    _closing = false;
    await windowManager.setPreventClose(true).catchError((_) {});
    if (!mounted) return;
    showErrorSnackBar(
      context,
      'This window would not close. Anything you sent has been sent — close it '
      'from the title bar.',
    );
  }

  Email? _originalEmail() {
    final raw = widget.arguments['originalEmail'];
    if (raw == null) return null;
    final map = raw as Map<String, dynamic>;
    EmailAddress parseAddress(Map<String, dynamic> m) =>
        EmailAddress(address: m['address'] as String, name: m['name'] as String?);

    final bodyTypeStr = map['bodyType'] as String? ?? 'text';
    final receivedStr = map['receivedDateTime'] as String?;
    final attachmentsJson = map['attachments'] as List<dynamic>? ?? [];

    return Email(
      id: map['id'] as String,
      subject: map['subject'] as String,
      from: parseAddress(map['from'] as Map<String, dynamic>),
      toRecipients: (map['toRecipients'] as List<dynamic>)
          .map((r) => parseAddress(r as Map<String, dynamic>))
          .toList(),
      ccRecipients: (map['ccRecipients'] as List<dynamic>)
          .map((r) => parseAddress(r as Map<String, dynamic>))
          .toList(),
      bodyPreview: '',
      body: map['body'] as String? ?? '',
      bodyType: bodyTypeStr == 'html' ? EmailBodyType.html : EmailBodyType.text,
      isRead: true,
      receivedDateTime: receivedStr != null
          ? DateTime.tryParse(receivedStr) ?? DateTime.now()
          : DateTime.now(),
      importance: EmailImportance.normal,
      attachments: attachmentsJson.map((a) {
        final aMap = a as Map<String, dynamic>;
        return EmailAttachment(
          id: aMap['id'] as String,
          name: aMap['name'] as String,
          contentType: aMap['contentType'] as String,
          size: (aMap['size'] as num).toInt(),
        );
      }).toList(),
      inlineAttachments:
          ComposeWindowApp._inlineAttachmentsFromJson(map['inlineAttachments']),
    );
  }

  Email? _draftEmail() {
    final raw = widget.arguments['draftEmail'];
    if (raw == null) return null;
    final map = raw as Map<String, dynamic>;
    EmailAddress parseAddress(Map<String, dynamic> m) =>
        EmailAddress(address: m['address'] as String, name: m['name'] as String?);
    final bodyTypeStr = map['bodyType'] as String? ?? 'text';
    final attachmentsJson = map['attachments'] as List<dynamic>? ?? [];
    return Email(
      id: '',
      subject: map['subject'] as String? ?? '',
      from: const EmailAddress(address: '', name: null),
      toRecipients: (map['toRecipients'] as List<dynamic>? ?? [])
          .map((r) => parseAddress(r as Map<String, dynamic>))
          .toList(),
      ccRecipients: (map['ccRecipients'] as List<dynamic>? ?? [])
          .map((r) => parseAddress(r as Map<String, dynamic>))
          .toList(),
      bodyPreview: '',
      body: map['body'] as String? ?? '',
      bodyType: bodyTypeStr == 'html' ? EmailBodyType.html : EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime.now(),
      importance: EmailImportance.normal,
      attachments: attachmentsJson.map((a) {
        final aMap = a as Map<String, dynamic>;
        return EmailAttachment(
          id: aMap['id'] as String,
          name: aMap['name'] as String,
          contentType: aMap['contentType'] as String,
          size: (aMap['size'] as num).toInt(),
        );
      }).toList(),
      inlineAttachments:
          ComposeWindowApp._inlineAttachmentsFromJson(map['inlineAttachments']),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final account = sl<AccountManager>().activeAccount;
    final fromAddress = account == null
        ? ''
        : account.senderName.isNotEmpty
            ? '${account.senderName} <${account.emailAddress}>'
            : account.emailAddress;
    final accountId = account?.id;
    final accountDomain = _domainOf(account?.emailAddress);
    return BlocProvider(
      create: (_) => ComposeBloc(sendEmail: sl<SendEmail>()),
      child: Scaffold(
        backgroundColor: c.surfacePanel,
        body: BlocListener<ComposeBloc, ComposeState>(
          listener: (context, state) {
            if (state is ComposeSent) {
              _close();
            } else if (state is ComposeError) {
              showErrorSnackBar(context, state.message);
            }
          },
          child: ComposeForm(
            key: _formKey,
            mode: widget.mode,
            originalEmail: _originalEmail(),
            draftEmail: _draftEmail(),
            onClose: _close,
            fromAddress: fromAddress,
            accountId: accountId,
            accountDomain: accountDomain,
            accounts: sl<AccountManager>().accounts,
            scrollable: true,
            existingDraftId: widget.arguments['existingDraftId'] as String?,
            onTitleChanged: (title) => windowManager.setTitle(title),
            defaultComposeFormat: _defaultComposeFormat,
            signatureHtml: _signatureHtml,
          ),
        ),
      ),
    );
  }

  static String? _domainOf(String? email) {
    if (email == null) return null;
    final at = email.lastIndexOf('@');
    if (at < 0 || at == email.length - 1) return null;
    return email.substring(at + 1).toLowerCase();
  }
}

// ---------------------------------------------------------------------------
// Mobile full-screen compose route
// ---------------------------------------------------------------------------

class _MobileComposePage extends StatefulWidget {
  const _MobileComposePage({
    required this.mode,
    this.originalEmail,
    this.draftEmail,
    this.existingDraftId,
    this.onSent,
  });

  final ComposeMode mode;
  final Email? originalEmail;
  final Email? draftEmail;
  final String? existingDraftId;
  final VoidCallback? onSent;

  @override
  State<_MobileComposePage> createState() => _MobileComposePageState();
}

class _MobileComposePageState extends State<_MobileComposePage> {
  EmailBodyType _defaultComposeFormat = AppSettings.defaultComposeFormat;
  String _signatureHtml = '';

  @override
  void initState() {
    super.initState();
    sl<AppSettings>().loadDefaultComposeFormat().then((format) {
      if (mounted) setState(() => _defaultComposeFormat = format);
    });
    final signatureAccount = sl<AccountManager>().activeAccount;
    if (signatureAccount != null) {
      _signatureHtml = SignatureMergeEngine.merge(
          signatureAccount.signatureHtml, signatureAccount);
    }
  }

  static String? _domainOf(String? email) {
    if (email == null) return null;
    final at = email.lastIndexOf('@');
    if (at < 0 || at == email.length - 1) return null;
    return email.substring(at + 1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final account = sl<AccountManager>().activeAccount;
    final fromAddress = account == null
        ? ''
        : account.senderName.isNotEmpty
            ? '${account.senderName} <${account.emailAddress}>'
            : account.emailAddress;

    return BlocProvider(
      create: (_) => ComposeBloc(sendEmail: sl<SendEmail>()),
      child: Scaffold(
        backgroundColor: c.surfacePanel,
        body: SafeArea(
          child: BlocListener<ComposeBloc, ComposeState>(
            listener: (context, state) {
              if (state is ComposeSent || state is ComposeError) {
                if (state is ComposeError) {
                  showErrorSnackBar(context, state.message);
                }
                if (state is ComposeSent) {
                  Navigator.of(context).pop();
                  widget.onSent?.call();
                }
              }
            },
            child: ComposeForm(
              mode: widget.mode,
              originalEmail: widget.originalEmail,
              draftEmail: widget.draftEmail,
              onClose: () => Navigator.of(context).pop(),
              fromAddress: fromAddress,
              accountId: account?.id,
              accountDomain: _domainOf(account?.emailAddress),
              accounts: sl<AccountManager>().accounts,
              scrollable: true,
              existingDraftId: widget.existingDraftId,
              defaultComposeFormat: _defaultComposeFormat,
              signatureHtml: _signatureHtml,
            ),
          ),
        ),
      ),
    );
  }
}
