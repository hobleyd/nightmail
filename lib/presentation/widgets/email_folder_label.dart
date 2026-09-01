import 'dart:math' as math;

import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';

/// The folder name shown in brackets on an email list row, or null when the row
/// should carry none.
///
/// A folder listing carries messages from *other* folders — the copies in Sent
/// and the already-filed replies both providers expand a thread with — and
/// naming the folder is how a reader tells those apart from the mail that is
/// really here.
///
/// **A message that is in [currentFolder] gets no label.** The folder on screen
/// is already named at the top of the pane, so repeating it on nearly every row
/// of a listing is noise that crowds out the sender. The label is there to say
/// *elsewhere*, which is also why it survives being wrong-footed by the panel:
/// pass a null [currentFolder] and every row names its folder, which is what
/// search results and a focused thread want.
///
/// **A raw provider id is never rendered.** Gmail stamps every label a message
/// carries into [Email.folderIds] — `UNREAD`, `IMPORTANT`, `CATEGORY_PERSONAL`
/// among them — and a Graph folder id is meaningless to a reader. Anything that
/// does not resolve to a folder in [folderNames] is dropped, and a row with no
/// resolvable folder gets no brackets at all rather than a `Label_123`.
String? emailFolderLabel(
  Email email, {
  required Map<String, String> folderNames,
  EmailFolder? currentFolder,
}) {
  if (currentFolder != null && email.isInFolder(currentFolder.id)) return null;
  for (final id in email.folderIds) {
    final name = folderNames[id];
    if (name != null) return name;
  }
  final parentId = email.parentFolderId;
  return parentId == null ? null : folderNames[parentId];
}

/// How wide the bracketed folder is allowed to get on a row [rowWidth] wide.
///
/// The label is laid out at its natural size — the sender is the row's only
/// flexible child, and making the label flexible too would ellipsise it while
/// there was still room, since a Flex hands a loose child its share rather than
/// what it asks for. So it is capped instead, and the cap is a *fraction* as
/// well as a ceiling: on a narrow pane a flat 120 is most of the row, which
/// would squeeze the sender to nothing and then push the date off the end.
double folderLabelMaxWidth(double rowWidth) => math.min(120, rowWidth * 0.35);
