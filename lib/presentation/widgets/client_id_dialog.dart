import 'package:flutter/material.dart';

class OAuthCredentials {
  const OAuthCredentials({required this.clientId, this.clientSecret});
  final String clientId;
  final String? clientSecret;
}

/// Shows a dialog asking the user to enter (or confirm) OAuth credentials.
/// Returns the entered credentials, or null if the user cancelled.
Future<OAuthCredentials?> showClientIdDialog(
  BuildContext context, {
  required String provider,
  required String helpText,
  String? initialValue,
  bool requireSecret = false,
  String? initialSecret,
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
  });

  final String provider;
  final String helpText;
  final String? initialValue;
  final bool requireSecret;
  final String? initialSecret;

  @override
  State<_ClientIdDialog> createState() => _ClientIdDialogState();
}

class _ClientIdDialogState extends State<_ClientIdDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _idCtrl;
  late final TextEditingController _secretCtrl;

  @override
  void initState() {
    super.initState();
    _idCtrl = TextEditingController(text: widget.initialValue ?? '');
    _secretCtrl = TextEditingController(text: widget.initialSecret ?? '');
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.provider} — OAuth Credentials'),
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
              TextFormField(
                controller: _idCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Client ID'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Enter a Client ID' : null,
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
                  clientId: _idCtrl.text.trim(),
                  clientSecret: widget.requireSecret
                      ? _secretCtrl.text.trim()
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
