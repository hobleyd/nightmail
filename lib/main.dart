import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import 'core/platform/window_utils.dart';
import 'core/platform/windows_app_data_migration.dart';
import 'core/settings/window_bounds_service.dart';
import 'data/database/app_database.dart';
import 'data/services/inline_attachment_cache.dart';
import 'domain/usecases/send_email.dart';
import 'infrastructure/accounts/account_manager.dart';
import 'infrastructure/background/background_mail_service.dart';
import 'infrastructure/contacts/contact_cache_sync_service.dart';
import 'infrastructure/notifications/notification_service.dart';
import 'infrastructure/sync/cache_membership_repair_service.dart';
import 'injection_container.dart';
import 'presentation/blocs/account/account_cubit.dart';
import 'presentation/blocs/theme/theme_cubit.dart';
import 'presentation/blocs/theme/theme_state.dart';
import 'presentation/pages/account_selection_page.dart';
import 'presentation/pages/calendar_window.dart';
import 'presentation/pages/compose_window.dart';
import 'presentation/pages/email_view_window.dart';
import 'presentation/pages/event_edit_window.dart';
import 'presentation/pages/image_view_window.dart';
import 'presentation/pages/reminder_popup_window.dart';
import 'presentation/pages/tasks_window.dart';
import 'presentation/pages/home_page.dart';

/// Places a modestly-sized window centred on [displayBounds] so a subsequent
/// [WindowManager.maximize] / [WindowManager.setFullScreen] targets that
/// monitor rather than the default one the OS placed the window on at launch.
/// No-op when [displayBounds] is null.
Future<void> _prePositionOnDisplay(Rect? displayBounds) async {
  if (displayBounds == null) return;
  final w = math.min(1000.0, displayBounds.width * 0.6);
  final h = math.min(700.0, displayBounds.height * 0.6);
  final rect = Rect.fromLTWH(
    displayBounds.left + (displayBounds.width - w) / 2,
    displayBounds.top + (displayBounds.height - h) / 2,
    w,
    h,
  );
  try {
    await windowManager.setBounds(rect);
  } catch (_) {}
}

/// One `setBounds` does not necessarily put a window where it was asked to go.
///
/// **window_manager's bounds are logical pixels at the ratio the window is on
/// *now*.** `setBounds` multiplies the rect by whatever `devicePixelRatio` Dart
/// currently reports, so a rect saved on a 100%-scaled monitor is scaled by 1.25
/// while the window still sits on a 125% one — which is where a window starts,
/// since it is created on the primary display. Windows then sends
/// `WM_DPICHANGED` as the window crosses over, Dart's ratio catches up an
/// event-loop turn later, and only a second `setBounds` lands correctly. Linux
/// has its own version of this: the compositor overrides the position when the
/// window is first mapped.
///
/// So re-apply until the ratio stops moving. **The ratio is what has to be
/// checked, not the resulting rect**: `getBounds` divides by the same stale
/// ratio `setBounds` multiplied by, so it happily reports the rect that was
/// asked for while the window sits somewhere else entirely. A ratio that did
/// not change across the call is the real evidence that the multiplication was
/// the right one. Bounded, because nothing here may spin.
Future<void> _settleBounds(Rect target) async {
  var ratio = _viewDevicePixelRatio();
  await windowManager.setBounds(target);
  // macOS lays windows out in AppKit points, which don't change per display.
  if (!Platform.isWindows && !Platform.isLinux) return;
  for (var attempt = 0; attempt < 2; attempt++) {
    // The DPI change is dispatched on the platform thread and reaches this
    // isolate a turn later, so there is nothing to read without waiting.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final settled = _viewDevicePixelRatio();
    if (settled == ratio) return;
    ratio = settled;
    await windowManager.setBounds(target);
  }
}

/// The ratio `window_manager` will scale by — it reads the same implicit view.
double _viewDevicePixelRatio() =>
    WidgetsBinding.instance.platformDispatcher.implicitView?.devicePixelRatio ??
    1.0;

/// Puts the calling engine's window back where [restored] says it last was.
/// The pre-position before maximize/full-screen is what picks the monitor those
/// apply to — otherwise the OS uses whichever one it placed the window on.
///
/// [settleWhileHidden] is for a window *we* show: it settles the geometry
/// through [_settleBounds] before anything is on screen. The main window cannot
/// do that — the engine shows it on its first frame — so it corrects itself
/// after that frame instead, which is invisible there because the window appears
/// at the same moment. A sub-window doing it that way is the visible bug: it is
/// already on screen a beat before its first frame, so it opens at the wrong
/// place and then jumps.
Future<void> _applyRestoreState(
  WindowRestoreState restored, {
  bool settleWhileHidden = false,
}) async {
  if (restored.fullScreen) {
    await _prePositionOnDisplay(restored.displayBounds);
    await windowManager.setFullScreen(true);
  } else if (restored.maximized) {
    await _prePositionOnDisplay(restored.displayBounds);
    await windowManager.maximize();
  } else if (restored.bounds != null) {
    final bounds = restored.bounds!;
    if (settleWhileHidden) {
      await _settleBounds(bounds);
      return;
    }
    await windowManager.setBounds(bounds);
    if (Platform.isWindows || Platform.isLinux) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await windowManager.setBounds(bounds);
        } catch (_) {}
      });
    }
  }
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await windowManager.ensureInitialized();
  } catch (_) {
    // window_manager is not available in sub-window processes — safe to ignore.
  }

  if (args.firstOrNull == 'multi_window') {
    // Must precede configureDependencies() — services keyed off this decide at
    // construction time whether they may touch process-wide native resources.
    AppWindow.markAsSubWindow();
    final windowId = args[1];
    final arguments = args[2].isEmpty
        ? <String, dynamic>{}
        : jsonDecode(args[2]) as Map<String, dynamic>;

    await configureDependencies();
    await sl<AccountManager>().initialize();

    // `restore` is the geometry this kind of window was last left at, for the
    // kinds that record one. It wins over centring on the parent's screen — the
    // user put the window somewhere deliberately — but only if it is still
    // reachable on the displays connected now, which is what
    // loadValidatedBounds returning null means.
    Future<void> showSubWindow(
      WindowOptions options, {
      WindowRestoreState? restore,
    }) async {
      final screenInfoRaw =
          arguments['_screenInfo'] as Map<dynamic, dynamic>?;

      try {
        if (restore != null) {
          await windowManager.waitUntilReadyToShow(
            WindowOptions(size: options.size, title: options.title),
          );
          await _applyRestoreState(restore, settleWhileHidden: true);
        } else if (screenInfoRaw != null) {
          final vx = (screenInfoRaw['x'] as num).toDouble();
          final vy = (screenInfoRaw['y'] as num).toDouble();
          final vw = (screenInfoRaw['width'] as num).toDouble();
          final vh = (screenInfoRaw['height'] as num).toDouble();
          final mainH = (screenInfoRaw['mainScreenHeight'] as num).toDouble();
          final winW = options.size?.width ?? 800.0;
          final winH = options.size?.height ?? 600.0;

          await windowManager.waitUntilReadyToShow(
            WindowOptions(size: options.size, title: options.title),
          );
          // Center within the source screen.
          // Cocoa uses bottom-left origin; window_manager flips Y relative to
          // NSScreen.screens[0].frame.height (the "primary" screen height).
          final cocoaX = vx + (vw - winW) / 2;
          final cocoaY = vy + (vh - winH) / 2;
          await windowManager.setPosition(
            Offset(cocoaX, mainH - cocoaY - winH),
          );
        } else {
          await windowManager.waitUntilReadyToShow(options);
        }
      } catch (_) {}
      await (await WindowController.fromCurrentEngine()).show();
    }

    if (arguments['type'] == 'calendar') {
      await showSubWindow(
        const WindowOptions(size: Size(900, 640), center: true, title: 'Calendar'),
      );
      runApp(const CalendarWindowApp());
      return;
    }

    if (arguments['type'] == 'tasks') {
      await showSubWindow(
        const WindowOptions(size: Size(640, 520), center: true, title: 'Tasks'),
      );
      runApp(const TasksWindowApp());
      return;
    }

    if (arguments['type'] == 'eventEdit') {
      final rawEvent = arguments['event'] as Map<String, dynamic>?;
      final subject = rawEvent?['subject'] as String?;
      final title = rawEvent != null
          ? (subject?.isNotEmpty == true ? subject! : 'Edit Event')
          : 'New Event';
      await showSubWindow(
        WindowOptions(size: const Size(600, 580), center: true, title: title),
        restore: await eventEditWindowBounds.loadValidatedBounds(),
      );
      runApp(EventEditWindowApp(windowId: windowId, arguments: arguments));
      return;
    }

    if (arguments['type'] == 'eventReminder') {
      final title = arguments['eventTitle'] as String? ?? 'Reminder';
      await showSubWindow(
        WindowOptions(size: const Size(300, 160), center: true, title: title),
      );
      runApp(ReminderPopupWindowApp(arguments: arguments));
      return;
    }

    if (arguments['type'] == 'emailView') {
      final emailMap = arguments['email'] as Map<String, dynamic>? ?? {};
      final subject = emailMap['subject'] as String? ?? '';
      final title = subject.isNotEmpty ? subject : '(No Subject)';
      await showSubWindow(
        WindowOptions(size: const Size(720, 580), center: true, title: title),
      );
      runApp(EmailViewWindowApp(windowId: windowId, arguments: arguments));
      return;
    }

    if (arguments['type'] == 'imageView') {
      await showSubWindow(
        const WindowOptions(size: Size(900, 700), center: true, title: 'Image'),
      );
      runApp(ImageViewWindowApp(arguments: arguments));
      return;
    }

    final mode = ComposeMode.values.byName(
      arguments['mode'] as String? ?? 'newEmail',
    );

    final draftEmailRaw = arguments['draftEmail'] as Map<String, dynamic>?;
    final originalSubject =
        ((arguments['originalEmail'] as Map<String, dynamic>?)?['subject']
                as String?) ??
            '';
    final cleanSubject = originalSubject
        .replaceFirst(RegExp(r'^(?:re:\s*)+', caseSensitive: false), '')
        .trim();
    final title = draftEmailRaw != null
        ? () {
            final s = draftEmailRaw['subject'] as String? ?? '';
            return s.isNotEmpty ? s : 'Draft';
          }()
        : switch (mode) {
            ComposeMode.newEmail => 'New Email',
            ComposeMode.reply || ComposeMode.replyAll =>
              cleanSubject.isNotEmpty ? 'Re: $cleanSubject' : 'Reply',
            ComposeMode.forward =>
              originalSubject.isNotEmpty ? 'Fwd: $originalSubject' : 'Forward',
          };

    await showSubWindow(
      WindowOptions(size: const Size(640, 520), center: true, title: title),
      restore: await composeWindowBounds.loadValidatedBounds(),
    );

    runApp(ComposeWindowApp(windowId: windowId, arguments: arguments));
    return;
  }

  // Relocates app data left in the directory the old Windows `CompanyName`
  // resolved to. Main window only — a sub-window cannot exist until this has
  // run — and before configureDependencies(), because the service locator
  // reads the support directory (secure storage lives there on Windows).
  await migrateWindowsAppDataDirectory();
  await configureDependencies();
  // Sweeps inline-image directories left behind by emails whose id the server
  // reassigned (a move), which per-email eviction cannot know about.
  unawaited(sl<InlineAttachmentCache>().prune());
  await BackgroundMailService.initialize();
  await BackgroundMailService.schedulePeriodicCheck();
  // Refresh the address-book cache behind the recipient typeahead if it has
  // gone stale (at most once a day per account), and keep re-checking for
  // sessions that stay open for days. Deliberately not awaited — it pulls
  // whole directories over the network, and the dropdown reads whatever is
  // already cached in the meantime.
  unawaited(_startContactCacheSync());
  // Files cached mail back under its own folder where an older build's cache
  // moved it into whichever folder was listed last. Once per account, and not
  // awaited: the folder on screen is served from the cache as it stands and
  // repainted from the network anyway.
  unawaited(_repairCacheMembership());
  // Initialize the notification plugin and check whether the app was launched
  // by a notification tap (handles iOS/Android terminated-state cold starts).
  // Must complete before runApp so that _pendingAction is set before
  // _HomeViewState.initState() calls takePendingAction().
  await sl<NotificationService>().initializeAndCheckLaunch();
  unawaited(sl<NotificationService>().requestPermission());

  if (!kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
    try {
      final restored = await WindowBoundsService().loadValidatedBounds();
      if (restored != null) await _applyRestoreState(restored);
    } catch (_) {}
  }

  runApp(const NightMailApp());
}

/// Brings the recipient typeahead's address-book cache up to date and keeps it
/// there. Only the main window does this: `desktop_multi_window` gives each
/// secondary window its own engine and therefore its own service locator, so
/// starting it anywhere else would have several isolates writing the same
/// SQLite file at once.
///
/// AccountCubit owns the call to `AccountManager.initialize()`, so this waits
/// on the manager's `ready` future rather than initialising it a second time.
/// The timeout is a backstop for the keychain-unavailable path, where
/// initialize can fail and never complete.
Future<void> _startContactCacheSync() async {
  try {
    await sl<AccountManager>().ready.timeout(const Duration(seconds: 30));
    final sync = sl<ContactCacheSyncService>();
    sync.startPeriodicRefresh();
    await sync.syncAll();
  } catch (e) {
    debugPrint('[Contacts] initial cache sync skipped: $e');
  }
}

/// Main window only, and for the same reason as the address book above: each
/// secondary window has its own service locator, and this writes the shared
/// SQLite file. Waits on the account manager because it repairs per account.
Future<void> _repairCacheMembership() async {
  try {
    await sl<AccountManager>().ready.timeout(const Duration(seconds: 30));
    await sl<CacheMembershipRepairService>().repairAll();
  } catch (e) {
    debugPrint('[CacheRepair] skipped: $e');
  }
}

class NightMailApp extends StatefulWidget {
  const NightMailApp({super.key});

  @override
  State<NightMailApp> createState() => _NightMailAppState();
}

class _NightMailAppState extends State<NightMailApp> with WindowListener {
  final _windowBoundsService = WindowBoundsService();
  Timer? _boundsDebounce;
  // Suppress saves triggered by the compositor repositioning the window during
  // startup (Linux/Wayland places the window after it is mapped, firing
  // onWindowMove before the user has touched anything).
  bool _suppressBoundsSave = Platform.isLinux;

  // On macOS, Cmd-Q calls -[NSApplication terminate:] directly — it does not
  // go through windowShouldClose/onWindowClose below, so AppDelegate.swift's
  // applicationShouldTerminate holds termination and invokes this channel to
  // give Dart a chance to shut down cleanly first.
  static const _appLifecycleChannel =
      MethodChannel('au.com.sharpblue.nightmail/app_lifecycle');
  bool _shutdownStarted = false;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  static ThemeData _buildTheme({String? fontFamily, bool dark = false}) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C83FD),
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      fontFamily: fontFamily,
      useMaterial3: true,
    );
  }

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
    if (Platform.isMacOS) {
      _appLifecycleChannel.setMethodCallHandler((call) async {
        if (call.method == 'applicationWillTerminate') {
          await _prepareForShutdown();
        }
        return null;
      });
    }
    if (_suppressBoundsSave) {
      Timer(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        setState(() => _suppressBoundsSave = false);
        // Save the compositor-settled position so subsequent restarts are
        // stable. On Wayland the compositor can override our setBounds request,
        // so without this save the window shifts every restart.
        _scheduleBoundsSave();
      });
    }
  }

  @override
  void dispose() {
    _boundsDebounce?.cancel();
    if (_isDesktop) windowManager.removeListener(this);
    super.dispose();
  }

  void _scheduleBoundsSave() {
    if (_suppressBoundsSave) return;
    _boundsDebounce?.cancel();
    _boundsDebounce = Timer(
      const Duration(milliseconds: 500),
      () async {
        try {
          // Special states are handled by their own event overrides below.
          if (await windowManager.isMaximized()) return;
          if (await windowManager.isFullScreen()) return;
          final bounds = await windowManager.getBounds();
          await _windowBoundsService.saveBounds(bounds);
        } catch (_) {}
      },
    );
  }

  Future<void> _saveCurrentState() async {
    try {
      final isFullScreen = await windowManager.isFullScreen();
      final isMaximized = await windowManager.isMaximized();
      final bounds = await windowManager.getBounds();
      await _windowBoundsService.saveBounds(
        bounds,
        fullScreen: isFullScreen,
        maximized: isMaximized,
      );
    } catch (_) {}
  }

  // The drift cache database runs on a background isolate. Close it through
  // drift's own shutdown protocol before tearing down the engine/process,
  // otherwise the isolate can be killed mid-query, crashing native sqlite3
  // (SIGSEGV in sqlite3Close) instead of shutting down cleanly. Guarded so
  // both the windowShouldClose path (onWindowClose) and the Cmd-Q path
  // (applicationShouldTerminate, via _appLifecycleChannel above) can call
  // this without racing or closing twice.
  Future<void> _prepareForShutdown() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    _boundsDebounce?.cancel();
    // Close the database first and give it the lion's share of the shutdown
    // budget — it's the crash-critical step. Window-bounds save is best
    // effort and shouldn't eat into the time a draining query needs.
    try {
      await sl<AppDatabase>().close().timeout(const Duration(seconds: 3));
    } catch (_) {}
    await _saveCurrentState();
  }

  @override
  void onWindowClose() async {
    // Quit the whole app when the main window is closed, even if
    // compose windows are still open.
    await _prepareForShutdown();
    windowManager.destroy();
  }

  // Save immediately when entering a special state so a subsequent quit
  // doesn't have to re-query the (now-changed) window state.
  @override
  void onWindowMaximize() => _saveCurrentState();

  @override
  void onWindowEnterFullScreen() => _saveCurrentState();

  // macOS/Windows: fires once when resize/move finishes.
  @override
  void onWindowResized() => _scheduleBoundsSave();

  @override
  void onWindowMoved() => _scheduleBoundsSave();

  // Linux: fires continuously during resize/move — debounce handles it.
  @override
  void onWindowResize() => _scheduleBoundsSave();

  @override
  void onWindowMove() => _scheduleBoundsSave();

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ThemeCubit>(
      create: (_) => sl<ThemeCubit>()..load(),
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          final lightTheme = _buildTheme(fontFamily: themeState.fontFamily);
          final darkTheme = _buildTheme(fontFamily: themeState.fontFamily, dark: true);
          return BlocProvider<AccountCubit>(
            create: (_) => sl<AccountCubit>()..initialize(),
            child: MaterialApp(
              title: 'NightMail',
              debugShowCheckedModeBanner: false,
              theme: lightTheme,
              darkTheme: darkTheme,
              themeMode: switch (themeState.mode) {
                AppThemeMode.light => ThemeMode.light,
                AppThemeMode.dark => ThemeMode.dark,
                AppThemeMode.system => ThemeMode.system,
              },
              builder: (context, child) {
                final scale = themeState.fontScale;
                if (scale == 1.0) return child!;
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: child!,
                );
              },
              home: const _AccountGate(),
            ),
          );
        },
      ),
    );
  }
}

class _AccountGate extends StatelessWidget {
  const _AccountGate();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AccountCubit, AccountState>(
      builder: (context, state) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (state) {
            AccountLoading() => const _SplashScreen(),
            AccountNoAccounts() => const AccountSelectionPage(),
            AccountsLoaded() => const HomePage(),
            AccountError(:final message) => _ErrorRetryScreen(message: message),
          },
        );
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF7C83FD),
          strokeWidth: 2,
        ),
      ),
    );
  }
}

class _ErrorRetryScreen extends StatelessWidget {
  const _ErrorRetryScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: Color(0xFF7C83FD),
              ),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => context.read<AccountCubit>().initialize(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
