import 'package:flutter/material.dart';

class MicrosoftOAuthInput {
  const MicrosoftOAuthInput({
    required this.clientId,
    required this.tenantId,
    required this.redirectUri,
    this.clientSecret,
  });

  final String clientId;
  final String tenantId;
  final String redirectUri;
  final String? clientSecret;
}

class GoogleOAuthInput {
  const GoogleOAuthInput({
    required this.clientId,
    this.clientSecret,
  });

  final String clientId;
  final String? clientSecret;
}

Future<MicrosoftOAuthInput?> showMicrosoftCredentialsDialog(
  BuildContext context, {
  String? currentClientId,
  String? currentTenantId,
  String? currentClientSecret,
  String? currentRedirectUri,
}) {
  return showDialog<MicrosoftOAuthInput>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _MicrosoftCredentialsDialog(
      initialClientId: currentClientId,
      initialTenantId: currentTenantId,
      initialClientSecret: currentClientSecret,
      initialRedirectUri: currentRedirectUri,
    ),
  );
}

Future<GoogleOAuthInput?> showGoogleCredentialsDialog(
  BuildContext context, {
  String? currentClientId,
  String? currentClientSecret,
}) {
  return showDialog<GoogleOAuthInput>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _GoogleCredentialsDialog(
      initialClientId: currentClientId,
      initialClientSecret: currentClientSecret,
    ),
  );
}

// ---------------------------------------------------------------------------
// Microsoft dialog
// ---------------------------------------------------------------------------

class _MicrosoftCredentialsDialog extends StatefulWidget {
  const _MicrosoftCredentialsDialog({
    this.initialClientId,
    this.initialTenantId,
    this.initialClientSecret,
    this.initialRedirectUri,
  });

  final String? initialClientId;
  final String? initialTenantId;
  final String? initialClientSecret;
  final String? initialRedirectUri;

  @override
  State<_MicrosoftCredentialsDialog> createState() =>
      _MicrosoftCredentialsDialogState();
}

class _MicrosoftCredentialsDialogState
    extends State<_MicrosoftCredentialsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _clientIdCtrl;
  late final TextEditingController _tenantIdCtrl;
  late final TextEditingController _clientSecretCtrl;
  late final TextEditingController _redirectUriCtrl;
  bool _obscureSecret = true;

  @override
  void initState() {
    super.initState();
    _clientIdCtrl =
        TextEditingController(text: widget.initialClientId ?? '');
    _tenantIdCtrl =
        TextEditingController(text: widget.initialTenantId ?? '');
    _clientSecretCtrl =
        TextEditingController(text: widget.initialClientSecret ?? '');
    _redirectUriCtrl =
        TextEditingController(text: widget.initialRedirectUri ?? 'nightmail://auth-callback');
  }

  @override
  void dispose() {
    _clientIdCtrl.dispose();
    _tenantIdCtrl.dispose();
    _clientSecretCtrl.dispose();
    _redirectUriCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Microsoft 365 Credentials'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter the credentials from your Azure app registration.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _clientIdCtrl,
                  decoration: const InputDecoration(labelText: 'Client ID'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Enter a Client ID' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _tenantIdCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Tenant ID',
                    hintText: 'e.g. contoso.onmicrosoft.com or GUID',
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Enter a Tenant ID' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _clientSecretCtrl,
                  obscureText: _obscureSecret,
                  decoration: InputDecoration(
                    labelText: 'Client Secret (optional)',
                    hintText: 'Leave blank for public client apps',
                    suffixIcon: IconButton(
                      icon: Icon(_obscureSecret
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscureSecret = !_obscureSecret),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _redirectUriCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Redirect URI',
                    hintText: 'nightmail://auth-callback',
                  ),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter a Redirect URI'
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(
                context,
                MicrosoftOAuthInput(
                  clientId: _clientIdCtrl.text.trim(),
                  tenantId: _tenantIdCtrl.text.trim(),
                  redirectUri: _redirectUriCtrl.text.trim(),
                  clientSecret: _clientSecretCtrl.text.trim().isEmpty
                      ? null
                      : _clientSecretCtrl.text.trim(),
                ),
              );
            }
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Google dialog
// ---------------------------------------------------------------------------

class _GoogleCredentialsDialog extends StatefulWidget {
  const _GoogleCredentialsDialog({
    this.initialClientId,
    this.initialClientSecret,
  });

  final String? initialClientId;
  final String? initialClientSecret;

  @override
  State<_GoogleCredentialsDialog> createState() =>
      _GoogleCredentialsDialogState();
}

class _GoogleCredentialsDialogState extends State<_GoogleCredentialsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _clientIdCtrl;
  late final TextEditingController _clientSecretCtrl;
  bool _obscureSecret = true;

  @override
  void initState() {
    super.initState();
    _clientIdCtrl =
        TextEditingController(text: widget.initialClientId ?? '');
    _clientSecretCtrl =
        TextEditingController(text: widget.initialClientSecret ?? '');
  }

  @override
  void dispose() {
    _clientIdCtrl.dispose();
    _clientSecretCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Gmail Credentials'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter the credentials from your Google Cloud Console OAuth app.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _clientIdCtrl,
                  decoration: const InputDecoration(labelText: 'Client ID'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Enter a Client ID' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _clientSecretCtrl,
                  obscureText: _obscureSecret,
                  decoration: InputDecoration(
                    labelText: 'Client Secret (optional)',
                    hintText: 'Leave blank for public client apps',
                    suffixIcon: IconButton(
                      icon: Icon(_obscureSecret
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscureSecret = !_obscureSecret),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(
                context,
                GoogleOAuthInput(
                  clientId: _clientIdCtrl.text.trim(),
                  clientSecret: _clientSecretCtrl.text.trim().isEmpty
                      ? null
                      : _clientSecretCtrl.text.trim(),
                ),
              );
            }
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
