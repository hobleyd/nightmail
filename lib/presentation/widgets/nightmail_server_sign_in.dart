import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/app_config.dart';
import '../../core/error/exceptions.dart';
import '../../data/datasources/remote/graph_api_datasource_impl.dart';
import '../../domain/usecases/discover_nightware_server.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/auth/microsoft_auth_service.dart';
import '../../infrastructure/auth/signed_in_mailbox_lookup.dart';
import '../../infrastructure/auth/token_storage.dart';
import '../../infrastructure/http/graph_http_client.dart';
import '../../injection_container.dart';
import 'adaptive_alert_dialog.dart';

/// Asks for a NightMail Server's address. Returns what was typed, or null if
/// the user cancelled; [signInToNightmailServer] normalises and validates it.
Future<String?> showNightmailServerDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _NightmailServerDialog(),
  );
}

/// Adds an account on the NightMail Server at [serverUrl]: discovers its
/// endpoints (`/.well-known/nightware`), runs the same PKCE sign-in a
/// Microsoft 365 account does against them, and reads the profile and
/// addresses through the same Graph datasource and lookup. The result is an
/// ordinary [MicrosoftAccount] carrying the server's configuration in
/// [MicrosoftAccount.server], not yet added — the caller hands it to
/// `AccountCubit.addAccount`, as the Microsoft button does.
///
/// Throws [AuthException] when discovery fails (its message is shown to the
/// user) and whatever the sign-in itself throws.
Future<MicrosoftAccount> signInToNightmailServer(String serverUrl) async {
  final discovered = await sl<DiscoverNightwareServer>()(serverUrl);
  final endpoints = discovered.fold(
    (failure) => throw AuthException(message: failure.message),
    (endpoints) => endpoints,
  );

  final id = const Uuid().v4();
  final authService = MicrosoftAuthService(
    clientId: endpoints.clientId!,
    tenantId: MicrosoftAccount.nightmailServerTenantId,
    redirectUri: AppConfig.microsoftRedirectUri,
    tokenStorage:
        TokenStorage(sl<FlutterSecureStorage>(), storageKey: 'token_$id'),
    endpoints: endpoints,
  );

  final token = await authService.signIn();

  final ds = GraphApiDatasourceImpl(
    client: GraphHttpClient(
      authService: authService,
      baseUrl: endpoints.graphBaseUrl,
    ),
    betaBaseUrl: endpoints.graphBetaBaseUrl,
  );
  final profile = await ds.fetchUserProfile();
  // Best-effort, as for Microsoft — see Account.aliases.
  final addresses =
      await GraphMailboxLookup(graphBaseUrl: endpoints.graphBaseUrl)
          .addressesFor(token);

  return MicrosoftAccount(
    id: id,
    displayName: profile.displayName,
    emailAddress: profile.email,
    tenantId: MicrosoftAccount.nightmailServerTenantId,
    clientId: endpoints.clientId,
    server: endpoints,
  ).withMailboxAddresses(addresses) as MicrosoftAccount;
}

class _NightmailServerDialog extends StatefulWidget {
  const _NightmailServerDialog();

  @override
  State<_NightmailServerDialog> createState() => _NightmailServerDialogState();
}

class _NightmailServerDialogState extends State<_NightmailServerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, _urlCtrl.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveAlertDialog(
      title: const Text('Sign in to a NightMail Server'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the address of your organisation\'s NightMail '
                'Server. NightMail reads its sign-in settings from the '
                'server, then opens its sign-in page.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _urlCtrl,
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Server address',
                  hintText: 'mail.example.com',
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? 'Enter the server address'
                    : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
