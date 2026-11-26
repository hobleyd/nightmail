import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/config/app_config.dart';
import '../../core/error/exceptions.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/graph_endpoints.dart';
import '../../infrastructure/accounts/account.dart';
import '../blocs/account/account_cubit.dart';
import '../widgets/nightmail_server_sign_in.dart';
import 'account_selection_page.dart';

/// What a launch with no accounts shows. A native app runs as the person
/// signed in to the device, so it offers every provider
/// ([AccountSelectionPage]). The web build is a public site that anyone can
/// open, so it offers only the sign-in to its own NightMail Server
/// ([WebSignInPage]). An account on that server is the only way in, and
/// nobody reaches a provider chooser without one. The web build can't use the
/// other providers anyway: Microsoft 365 and Gmail have no web client
/// registered for its origin, and a browser can't open IMAP's sockets.
Widget noAccountsPage({required bool isWeb}) => isWeb
    ? const WebSignInPage(server: AppConfig.nightwareServer)
    : const AccountSelectionPage();

/// The web build's first page: sign in to [server] (Keycloak, through the
/// server's own `/.well-known/nightware` sign-in), and that sign-in becomes
/// the account. [server] comes from `--dart-define=NIGHTWARE_SERVER`; empty
/// means a development build, which asks for the address instead.
///
/// With a server configured, the page offers no address field. Otherwise
/// anyone could sign in through a Keycloak of their own and pass the gate.
class WebSignInPage extends StatefulWidget {
  const WebSignInPage({super.key, required this.server});

  final String server;

  @override
  State<WebSignInPage> createState() => _WebSignInPageState();
}

class _WebSignInPageState extends State<WebSignInPage> {
  /// Discovered when the page opens, not on the click, and the button waits
  /// for it: the sign-in opens a popup, and a browser blocks one that opens
  /// after an awaited network round trip has used up the click's user
  /// activation.
  GraphEndpoints? _endpoints;
  bool _discovering = false;
  bool _isLoading = false;
  String? _error;

  /// Bumped by each sign-in and by Cancel, so a sign-in the user gave up on
  /// (a popup they closed never answers) can't touch the page afterwards.
  int _attempt = 0;

  bool get _fixedServer => widget.server.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_fixedServer) _discover();
  }

  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _error = null;
    });
    try {
      final endpoints = await discoverNightmailServer(widget.server);
      if (mounted) setState(() => _endpoints = endpoints);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  static String _message(Object e) =>
      e is AuthException ? e.message : e.toString();

  Future<void> _signIn() async {
    final accountCubit = context.read<AccountCubit>();
    final Future<MicrosoftAccount> signingIn;
    if (_fixedServer) {
      // Synchronous up to the popup: nothing awaited before it opens.
      signingIn = signInWithNightmailServerEndpoints(_endpoints!);
    } else {
      final typed = await showNightmailServerDialog(context);
      if (typed == null || !mounted) return;
      signingIn = signInToNightmailServer(typed);
    }

    final attempt = ++_attempt;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final account = await signingIn;
      if (mounted && attempt == _attempt) {
        await accountCubit.addAccount(account);
      }
    } catch (e) {
      if (mounted && attempt == _attempt) {
        setState(() => _error = _message(e));
      }
    } finally {
      if (mounted && attempt == _attempt) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _cancel() => setState(() {
        _attempt++;
        _isLoading = false;
      });

  Widget _primary() {
    if (_isLoading) {
      return Column(
        children: [
          const CircularProgressIndicator(
            color: AppColors.accent,
            strokeWidth: 2,
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: _cancel, child: const Text('Cancel')),
        ],
      );
    }
    if (_fixedServer && _endpoints == null && !_discovering) {
      return _button('Try again', _discover);
    }
    return _button(
      'Sign in',
      _fixedServer && _endpoints == null ? null : _signIn,
    );
  }

  Widget _button(String label, VoidCallback? onPressed) => SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF111827),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: 0,
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final host = Uri.tryParse(widget.server)?.host;
    return Scaffold(
      backgroundColor: c.surfaceBase,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: c.logoContainerBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: c.logoContainerBorder),
                      ),
                      child: const Icon(
                        Icons.mail_outline_rounded,
                        size: 36,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'NightMail',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    host == null || host.isEmpty
                        ? 'Sign in with your NightMail Server account.'
                        : 'Sign in with your account on $host.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.textMuted, fontSize: 14),
                  ),
                  const SizedBox(height: 40),
                  _primary(),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.errorBannerText, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
