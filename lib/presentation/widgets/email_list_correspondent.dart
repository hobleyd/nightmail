/// Who a list row is headed by.
///
/// An incoming folder names the sender: that is who the reader is hearing from.
/// In Sent every message is from the reader, so a column of their own name says
/// nothing, and the row names who the message went to instead — the one thing
/// that distinguishes one sent message from the next.
library;

import '../../domain/entities/email.dart';
import 'email_list_conversations.dart';

/// Whether a row in a folder listing should lead with its recipients.
///
/// Only in an outgoing folder ([outgoingFolder], from `isOutgoingMailFolder`),
/// and only for the reader's own messages: a Sent listing also carries the
/// correspondent's replies that both providers expand a thread with, and those
/// rows still want the sender — "To: me" would hide who wrote back. With no
/// [selfAddress] to compare against, every row in an outgoing folder is taken
/// as the reader's own, which is what the folder holds.
bool showsRecipients(
  Email email, {
  required bool outgoingFolder,
  String? selfAddress,
}) {
  if (!outgoingFolder) return false;
  if (selfAddress == null || selfAddress.trim().isEmpty) return true;
  return isFromSelf(email, selfAddress.trim().toLowerCase());
}

/// The name a list row leads with.
///
/// The sender, unless [showRecipients] asks for the recipients — or the
/// message has no sender at all, which is an unsent draft (Graph returns those
/// with an empty from address), and a Drafts list of blank rows is useless.
/// A message with no one in To or Cc falls back to the sender either way, so a
/// row is never blank when there is something to say.
String emailListCorrespondent(Email email, {bool showRecipients = false}) {
  if (showRecipients || email.from.address.isEmpty) {
    final recipients = _recipientsLabel(email);
    if (recipients != null) return recipients;
  }
  return email.from.address.isEmpty ? '' : email.from.displayName;
}

/// "To: Ann, Bob…" — at most two names, then an ellipsis. Cc stands in when
/// there is nobody in To, as with a message sent to a list by Cc.
String? _recipientsLabel(Email email) {
  final recipients =
      email.toRecipients.isNotEmpty ? email.toRecipients : email.ccRecipients;
  if (recipients.isEmpty) return null;
  final names = recipients.take(2).map((r) => r.displayName).join(', ');
  return 'To: $names${recipients.length > 2 ? '…' : ''}';
}
