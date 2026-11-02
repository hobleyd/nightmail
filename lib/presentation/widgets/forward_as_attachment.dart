import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/utils/subject_prefixes.dart';
import '../../domain/entities/local_attachment.dart';

/// A message to forward as an attachment: just what fetching and naming its
/// `.eml` needs, so it can cross into the desktop compose window as JSON.
typedef ForwardedMessage = ({String id, String subject});

/// What a forward of list rows opens compose with: the subject to seed, if
/// any, and each message's `.eml`.
typedef ForwardDraft = ({String? subject, List<LocalAttachment> attachments});

/// The subject a forward of [messages] starts with: `Fwd: …` for a single
/// message, none for several, since there is no one subject for them.
String? forwardSelectionSubject(List<ForwardedMessage> messages) =>
    messages.length == 1 ? forwardSubjectFor(messages.single.subject) : null;

/// Fetches the raw source of each of [messages] through [fetchRaw] and turns
/// it into a [ForwardDraft], or answers the first failure's message.
///
/// Nothing is returned unless every message arrived — a forward quietly
/// missing one the user picked is worse than one that says it could not be
/// made. Fetches run [batchSize] at a time: Select All can pick a
/// whole page, and each one is a full message download. Attachments keep the
/// order of [messages]; the subject is [forwardSelectionSubject].
Future<Either<String, ForwardDraft>> gatherForwardAttachments(
  List<ForwardedMessage> messages,
  Future<Either<Failure, Uint8List>> Function(String emailId) fetchRaw, {
  int batchSize = 4,
}) async {
  final attachments = <LocalAttachment>[];
  final usedNames = <String>{};
  for (var i = 0; i < messages.length; i += batchSize) {
    final batch = messages.skip(i).take(batchSize).toList();
    final results = await Future.wait(batch.map((e) => fetchRaw(e.id)));
    for (var j = 0; j < batch.length; j++) {
      final failure = results[j].getLeft().toNullable();
      if (failure != null) return Left(failure.message);
      attachments.add(LocalAttachment(
        name: emlFileName(batch[j].subject, usedNames),
        // Named explicitly: [LocalAttachment.mimeTypeFromName] has no entry
        // for .eml and would send it as application/octet-stream, which a
        // recipient's client offers as a download rather than opening as a
        // message.
        mimeType: 'message/rfc822',
        bytes: results[j].getOrElse((_) => Uint8List(0)),
      ));
    }
  }
  return Right((
    subject: forwardSelectionSubject(messages),
    attachments: attachments,
  ));
}

/// `<subject>.eml`, made safe for a file name and distinct from every name
/// already in [used] — two replies in one thread share a subject. Adds the
/// name it answers to [used].
String emlFileName(String subject, Set<String> used) {
  var base = subject.replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_').trim();
  if (base.length > 80) base = base.substring(0, 80).trim();
  if (base.isEmpty) base = 'message';
  var name = '$base.eml';
  for (var n = 2; !used.add(name); n++) {
    name = '$base ($n).eml';
  }
  return name;
}
