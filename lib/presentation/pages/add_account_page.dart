import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/oauth_credentials.dart';
import '../../core/config/oauth_credentials_storage.dart';
import '../../core/error/exceptions.dart';
import '../../core/theme/app_colors.dart';
import '../widgets/client_secret_dialog.dart';
import '../../data/datasources/remote/graph_api_datasource_impl.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/auth/gmail_auth_service.dart';
import '../../infrastructure/auth/imap_credential_storage.dart';
import '../../infrastructure/auth/microsoft_auth_service.dart';
import '../../infrastructure/auth/token_storage.dart';
import '../../infrastructure/http/graph_http_client.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';

/// Pushed from inside [HomePage] when the user wants to add another account.
class AddAccountPage extends StatefulWidget {
  const AddAccountPage({super.key});

  @override
  State<AddAccountPage> createState() => _AddAccountPageState();
}

class _AddAccountPageState extends State<AddAccountPage> {
  bool _isLoading = false;
  bool _isLoadingCredentials = true;
  String? _error;
  OAuthCredentials? _credentials;

  @override
  void initState() {
    super.initState();
    sl<OAuthCredentialsStorage>().load().then((creds) {
      if (mounted) {
        setState(() {
          _credentials = creds;
          _isLoadingCredentials = false;
        });
      }
    });
  }

  Future<void> _signInMicrosoft() async {
    final accountCubit = context.read<AccountCubit>();
    final nav = Navigator.of(context);

    final input = await showMicrosoftCredentialsDialog(
      context,
      currentClientId: _credentials?.microsoftClientId,
      currentTenantId: _credentials?.microsoftTenantId,
      currentClientSecret: _credentials?.microsoftClientSecret,
      currentRedirectUri: _credentials?.microsoftRedirectUri,
    );
    if (input == null || !mounted) return;

    final updatedCreds = _credentials!.copyWith(
      microsoftClientId: input.clientId,
      microsoftTenantId: input.tenantId,
      microsoftClientSecret: input.clientSecret,
      microsoftRedirectUri: input.redirectUri,
    );
    await sl<OAuthCredentialsStorage>().save(updatedCreds);
    if (!mounted) return;
    setState(() {
      _credentials = updatedCreds;
      _isLoading = true;
      _error = null;
    });

    try {
      const uuid = Uuid();
      final id = uuid.v4();
      final secureStorage = sl<FlutterSecureStorage>();
      final tokenStorage =
          TokenStorage(secureStorage, storageKey: 'token_$id');
      final creds = updatedCreds;
      final authService = MicrosoftAuthService(
        clientId: creds.microsoftClientId,
        tenantId: creds.microsoftTenantId,
        redirectUri: creds.microsoftRedirectUri,
        clientSecret: creds.microsoftClientSecret,
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
        tenantId: creds.microsoftTenantId,
      );

      if (mounted) {
        await accountCubit.addAccount(account);
        nav.pop();
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
    final accountCubit = context.read<AccountCubit>();
    final nav = Navigator.of(context);

    final input = await showGoogleCredentialsDialog(
      context,
      currentClientId: _credentials?.googleClientId,
      currentClientSecret: _credentials?.googleClientSecret,
    );
    if (input == null || !mounted) return;

    final updatedCreds = _credentials!.copyWith(
      googleClientId: input.clientId,
      googleClientSecret: input.clientSecret,
    );
    await sl<OAuthCredentialsStorage>().save(updatedCreds);
    if (!mounted) return;
    setState(() {
      _credentials = updatedCreds;
      _isLoading = true;
      _error = null;
    });

    try {
      const uuid = Uuid();
      final id = uuid.v4();
      final secureStorage = sl<FlutterSecureStorage>();
      final tokenStorage =
          TokenStorage(secureStorage, storageKey: 'token_$id');
      final creds = updatedCreds;
      final authService = GmailAuthService(
        clientId: creds.googleClientId,
        redirectUri: creds.googleRedirectUri,
        clientSecret: creds.googleClientSecret,
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
        nav.pop();
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
      appBar: AppBar(
        backgroundColor: c.surfaceBase,
        title: Text('Add Account', style: TextStyle(color: c.textPrimary)),
        iconTheme: IconThemeData(color: c.textPrimary),
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Choose a provider',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_isLoading || _isLoadingCredentials)
                    const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.accent,
                        strokeWidth: 2,
                      ),
                    )
                  else ...[
                    _ProviderButton(
                      label: 'Microsoft 365 / Outlook',
                      color: const Color(0xFF2F2FA2),
                      onTap: _signInMicrosoft,
                    ),
                    const SizedBox(height: 12),
                    _ProviderButton(
                      label: 'Gmail',
                      color: const Color(0xFFEA4335),
                      onTap: _signInGmail,
                    ),
                    const SizedBox(height: 12),
                    _ProviderButton(
                      label: 'IMAP / Other',
                      color: const Color(0xFF4B5563),
                      onTap: _showImapDialog,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
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
      ),
    );
  }
}

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: 0,
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w500)),
      ),
    );
  }
}

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
    required String portDefault,
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
                  portDefault: '993',
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
                  portDefault: '587',
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
