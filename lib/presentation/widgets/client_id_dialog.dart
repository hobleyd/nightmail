import 'package:flutter/material.dart';
import 'adaptive_alert_dialog.dart';

class OAuthCredentials {
  const OAuthCredentials({
    required this.clientId,
    this.clientSecret,
    this.tenantId,
  });
  final String clientId;
  final String? clientSecret;
  final String? tenantId;
}

/// Shows a dialog asking the user to enter (or confirm) OAuth credentials.
/// Returns the entered credentials, or null if the user cancelled.
///
/// Client ID/Secret/Tenant ID are all BYOA (bring-your-own-Azure-app/
/// Google-project) fields — most users never need to see any of them, since
/// [initialValue] (and, for Microsoft, [initialTenant]) are normally the
/// compiled defaults NightMail already signs in with. They all stay hidden
/// behind a single "custom app registration" toggle unless there is no
/// usable compiled default to fall back to silently.
Future<OAuthCredentials?> showClientIdDialog(
  BuildContext context, {
  required String provider,
  required String helpText,
  String? initialValue,
  bool requireSecret = false,
  String? initialSecret,
  bool requireTenant = false,
  String? initialTenant,
}) {
  return showDialog<OAuthCredentials>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ClientIdDialog(
      provider: provider,
      helpText: helpText,
      initialValue: initialValue,
      requireSecret: requireSecret,
      initialSecret: initialSecret,
      requireTenant: requireTenant,
      initialTenant: initialTenant,
    ),
  );
}

class _ClientIdDialog extends StatefulWidget {
  const _ClientIdDialog({
    required this.provider,
    required this.helpText,
    this.initialValue,
    this.requireSecret = false,
    this.initialSecret,
    this.requireTenant = false,
    this.initialTenant,
  });

  final String provider;
  final String helpText;
  final String? initialValue;
  final bool requireSecret;
  final String? initialSecret;
  final bool requireTenant;
  final String? initialTenant;

  @override
  State<_ClientIdDialog> createState() => _ClientIdDialogState();
}

class _ClientIdDialogState extends State<_ClientIdDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _idCtrl;
  late final TextEditingController _secretCtrl;
  late final TextEditingController _tenantCtrl;

  // Client ID/Secret/Tenant ID all start hidden unless there is no compiled
  // default to use silently — in that case there's nothing to hide behind,
  // so the fields must be shown immediately.
  late bool _advanced;

  @override
  void initState() {
    super.initState();
    _idCtrl = TextEditingController(text: widget.initialValue ?? '');
    _secretCtrl = TextEditingController(text: widget.initialSecret ?? '');
    _tenantCtrl = TextEditingController(text: widget.initialTenant ?? '');
    _advanced = widget.initialValue == null ||
        (widget.requireTenant && widget.initialTenant == null);
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _secretCtrl.dispose();
    _tenantCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveAlertDialog(
      title: Text('Sign in with ${widget.provider}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.helpText, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 16),
              if (_advanced) ...[
                if (widget.requireTenant) ...[
                  TextFormField(
                    controller: _tenantCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Tenant ID'),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'Enter a Tenant ID'
                        : null,
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _idCtrl,
                  autofocus: !widget.requireTenant,
                  decoration: const InputDecoration(labelText: 'Client ID'),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter a Client ID'
                      : null,
                ),
                if (widget.requireSecret) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _secretCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Client Secret'),
                    obscureText: true,
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'Enter a Client Secret'
                        : null,
                  ),
                ],
              ] else
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _advanced = true),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    child: const Text('Use a custom app registration'),
                  ),
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
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(
                context,
                OAuthCredentials(
                  clientId:
                      _advanced ? _idCtrl.text.trim() : widget.initialValue!,
                  clientSecret: widget.requireSecret
                      ? (_advanced
                          ? _secretCtrl.text.trim()
                          : widget.initialSecret)
                      : null,
                  tenantId: widget.requireTenant
                      ? (_advanced ? _tenantCtrl.text.trim() : widget.initialTenant)
                      : null,
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
