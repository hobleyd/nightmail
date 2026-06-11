import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/app_config.dart';
import '../../core/error/exceptions.dart';
import '../../core/theme/app_colors.dart';
import '../../data/datasources/remote/graph_api_datasource_impl.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/auth/gmail_auth_service.dart';
import '../../infrastructure/auth/imap_credential_storage.dart';
import '../../infrastructure/auth/microsoft_auth_service.dart';
import '../../infrastructure/auth/token_storage.dart';
import '../../infrastructure/http/graph_http_client.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';

/// Shown when no accounts are configured. Lets the user choose a provider.
class AccountSelectionPage extends StatefulWidget {
  const AccountSelectionPage({super.key, this.errorMessage});

  final String? errorMessage;

  @override
  State<AccountSelectionPage> createState() => _AccountSelectionPageState();
}

class _AccountSelectionPageState extends State<AccountSelectionPage> {
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.errorMessage;
  }

  Future<void> _signInMicrosoft() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final accountCubit = context.read<AccountCubit>();

    try {
      const uuid = Uuid();
      final id = uuid.v4();
      final secureStorage = sl<FlutterSecureStorage>();
      final tokenStorage = TokenStorage(
        secureStorage,
        storageKey: 'token_$id',
      );
      final authService = MicrosoftAuthService(
        clientId: AppConfig.microsoftClientId,
        tenantId: AppConfig.microsoftTenantId,
        redirectUri: AppConfig.microsoftRedirectUri,
        tokenStorage: tokenStorage,
      );

      await authService.signIn();

      final ds = GraphApiDatasourceImpl(
          client: GraphHttpClient(authService: authService));
      final profile = await ds.fetchUserProfile();

      final account = MicrosoftAccount(
        id: id,
        displayName: profile.displayName,
        emailAddress: profile.email,
        tenantId: AppConfig.microsoftTenantId,
      );

      if (mounted) {
        await accountCubit.addAccount(account);
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signInGmail() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final accountCubit = context.read<AccountCubit>();

    try {
      const uuid = Uuid();
      final id = uuid.v4();
      final secureStorage = sl<FlutterSecureStorage>();
      final tokenStorage = TokenStorage(
        secureStorage,
        storageKey: 'token_$id',
      );
      final authService = GmailAuthService(
        clientId: AppConfig.gmailClientId,
        redirectUri: AppConfig.gmailRedirectUri,
        tokenStorage: tokenStorage,
      );

      await authService.signIn();

      final account = GmailAccount(
        id: id,
        displayName: 'Gmail Account',
        emailAddress: '',
      );

      if (mounted) {
        await accountCubit.addAccount(account);
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showImapDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => BlocProvider.value(
        value: context.read<AccountCubit>(),
        child: const _ImapSetupDialog(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
                  const Spacer(flex: 2),
                  _Logo(),
                  const SizedBox(height: 40),
                  Text(
                    'Choose your email provider',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Connect an account to get started.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.textMuted, fontSize: 14),
                  ),
                  const Spacer(flex: 2),
                  if (_isLoading)
                    const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.accent,
                        strokeWidth: 2,
                      ),
                    )
                  else ...[
                    _ProviderButton(
                      label: 'Microsoft 365 / Outlook',
                      icon: _MicrosoftIcon(),
                      color: const Color(0xFF2F2FA2),
                      onTap: _signInMicrosoft,
                    ),
                    const SizedBox(height: 12),
                    _ProviderButton(
                      label: 'Gmail',
                      icon: _GmailIcon(),
                      color: const Color(0xFFEA4335),
                      onTap: _signInGmail,
                    ),
                    const SizedBox(height: 12),
                    _ProviderButton(
                      label: 'IMAP / Other',
                      icon: const Icon(Icons.email_outlined,
                          color: Colors.white, size: 20),
                      color: const Color(0xFF4B5563),
                      onTap: _showImapDialog,
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_error != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: c.errorBannerBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: c.errorBannerBorder),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline_rounded,
                              size: 16, color: Color(0xFFEF4444)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: c.errorBannerText,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: c.logoContainerBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.logoContainerBorder, width: 1),
          ),
          child: const Icon(
            Icons.mail_outline_rounded,
            size: 36,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'NightMail',
          style: TextStyle(
            color: context.colors.textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Widget icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          elevation: 0,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 20, height: 20, child: icon),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/// Microsoft "four squares" logo.
class _MicrosoftIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _MicrosoftLogoPainter());
  }
}

class _MicrosoftLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final half = size.width / 2;
    final gap = size.width * 0.05;
    final sq = half - gap;

    void drawSquare(double x, double y, Color color) {
      canvas.drawRect(Rect.fromLTWH(x, y, sq, sq), Paint()..color = color);
    }

    drawSquare(0, 0, const Color(0xFFF25022));
    drawSquare(half + gap, 0, const Color(0xFF7FBA00));
    drawSquare(0, half + gap, const Color(0xFF00A4EF));
    drawSquare(half + gap, half + gap, const Color(0xFFFFB900));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Simple "G" letter for Gmail.
class _GmailIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text(
      'G',
      style: TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
      textAlign: TextAlign.center,
    );
  }
}

// ---------------------------------------------------------------------------
// IMAP Setup Dialog
// ---------------------------------------------------------------------------

class _ImapSetupDialog extends StatefulWidget {
  const _ImapSetupDialog();

  @override
  State<_ImapSetupDialog> createState() => _ImapSetupDialogState();
}

class _ImapSetupDialogState extends State<_ImapSetupDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _imapHostCtrl = TextEditingController();
  final _imapPortCtrl = TextEditingController(text: '993');
  final _smtpHostCtrl = TextEditingController();
  final _smtpPortCtrl = TextEditingController(text: '587');
  final _passwordCtrl = TextEditingController();
  bool _imapUseSsl = true;
  bool _smtpUseSsl = false;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _imapHostCtrl.dispose();
    _imapPortCtrl.dispose();
    _smtpHostCtrl.dispose();
    _smtpPortCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });
    final accountCubit = context.read<AccountCubit>();
    final nav = Navigator.of(context);

    try {
      const uuid = Uuid();
      final id = uuid.v4();
      final email = _emailCtrl.text.trim();
      final imapHost = _imapHostCtrl.text.trim();
      final imapPort = int.tryParse(_imapPortCtrl.text.trim()) ?? 993;
      final smtpHost = _smtpHostCtrl.text.trim();
      final smtpPort = int.tryParse(_smtpPortCtrl.text.trim()) ?? 587;
      final password = _passwordCtrl.text;

      final account = ImapAccount(
        id: id,
        displayName: email,
        emailAddress: email,
        host: imapHost,
        port: imapPort,
        useSsl: _imapUseSsl,
        smtpHost: smtpHost,
        smtpPort: smtpPort,
        smtpUseSsl: _smtpUseSsl,
      );

      final credStorage = ImapCredentialStorage(sl<FlutterSecureStorage>());
      await credStorage.savePassword(id, password);

      if (mounted) {
        await accountCubit.addAccount(account);
        nav.pop();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _serverRow({
    required TextEditingController hostCtrl,
    required TextEditingController portCtrl,
    required String hostLabel,
    required bool useSsl,
    required ValueChanged<bool> onSslChanged,
    String? Function(String?)? hostValidator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: hostCtrl,
          decoration: InputDecoration(labelText: hostLabel),
          validator: hostValidator ??
              (v) => v == null || v.isEmpty ? 'Enter $hostLabel' : null,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: portCtrl,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
                validator: (v) =>
                    int.tryParse(v ?? '') == null ? 'Invalid port' : null,
              ),
            ),
            const SizedBox(width: 16),
            Column(
              children: [
                const Text('SSL', style: TextStyle(fontSize: 12)),
                Switch(value: useSsl, onChanged: onSslChanged),
              ],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add IMAP Account'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _emailCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Email address'),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Enter your email' : null,
                ),
                const SizedBox(height: 16),
                const Text('Incoming (IMAP)',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _serverRow(
                  hostCtrl: _imapHostCtrl,
                  portCtrl: _imapPortCtrl,
                  hostLabel: 'IMAP server',
                  useSsl: _imapUseSsl,
                  onSslChanged: (v) => setState(() => _imapUseSsl = v),
                  hostValidator: (v) =>
                      v == null || v.isEmpty ? 'Enter IMAP server' : null,
                ),
                const SizedBox(height: 16),
                const Text('Outgoing (SMTP)',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _serverRow(
                  hostCtrl: _smtpHostCtrl,
                  portCtrl: _smtpPortCtrl,
                  hostLabel: 'SMTP server',
                  useSsl: _smtpUseSsl,
                  onSslChanged: (v) => setState(() => _smtpUseSsl = v),
                  hostValidator: (v) =>
                      v == null || v.isEmpty ? 'Enter SMTP server' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordCtrl,
                  decoration:
                      const InputDecoration(labelText: 'App password'),
                  obscureText: true,
                  validator: (v) => v == null || v.isEmpty
                      ? 'Enter your app password'
                      : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                        color: Color(0xFFEF4444), fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add Account'),
        ),
      ],
    );
  }
}
