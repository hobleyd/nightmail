import 'package:enough_mail/enough_mail.dart';

final _namedAddress = RegExp(r'^\s*"?(.*?)"?\s*<([^>]+)>\s*$');

/// A recipient as the compose form spells it — `Name <addr>` for a picked
/// contact, a bare address otherwise — as a [MailAddress] whose name is
/// rendered quoted.
///
/// Handed to the builder as one string, a directory name of the
/// `Last, First` kind went out as `To: Last, First <addr>`: the comma makes
/// that two recipients, the first of them not an address. Gmail refuses the
/// message with a 400 (on send and on every draft save), and an SMTP server
/// that accepts it hands the recipient's side the same broken header.
MailAddress parseMailAddress(String raw) {
  final m = _namedAddress.firstMatch(raw);
  if (m == null) return MailAddress(null, raw.trim());
  final name = m.group(1)!.trim();
  return MailAddress(name.isEmpty ? null : name, m.group(2)!.trim());
}
