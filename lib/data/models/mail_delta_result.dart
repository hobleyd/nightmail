import 'email_model.dart';

class MailDeltaResult {
  const MailDeltaResult({
    required this.upserted,
    required this.removedIds,
    required this.deltaLink,
  });

  final List<EmailModel> upserted;
  final List<String> removedIds;
  final String deltaLink;

  bool get hasChanges => upserted.isNotEmpty || removedIds.isNotEmpty;
}
