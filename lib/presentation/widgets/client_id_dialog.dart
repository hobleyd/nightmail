import 'package:flutter/material.dart';

/// Shows a dialog asking the user to enter (or confirm) an OAuth Client ID.
/// Returns the trimmed ID string, or null if the user cancelled.
Future<String?> showClientIdDialog(
  BuildContext context, {
  required String provider,
  required String helpText,
  String? initialValue,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ClientIdDialog(
      provider: provider,
      helpText: helpText,
      initialValue: initialValue,
    ),
  );
}

class _ClientIdDialog extends StatefulWidget {
  const _ClientIdDialog({
    required this.provider,
    required this.helpText,
    this.initialValue,
  });

  final String provider;
  final String helpText;
  final String? initialValue;

  @override
  State<_ClientIdDialog> createState() => _ClientIdDialogState();
}

class _ClientIdDialogState extends State<_ClientIdDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.provider} — Client ID'),
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
                controller: _ctrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Client ID'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Enter a Client ID' : null,
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
              Navigator.pop(context, _ctrl.text.trim());
            }
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
