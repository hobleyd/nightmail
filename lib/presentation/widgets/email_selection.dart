import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_detail/email_detail_state.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/email_list/email_list_state.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_event.dart';
import '../blocs/folder_list/folder_list_state.dart';
import '../blocs/home/home_cubit.dart';
import '../blocs/mail_poller/mail_poller_cubit.dart';

/// Opens [email] in the reading pane: selects it, loads its full content, and
/// marks its thread read once that content actually finishes loading.
///
/// The one place a tapped row, or an adjacent thread reached by a reading-pane
/// swipe, becomes the message on screen — see [markThreadReadOnceLoaded] for
/// why marking waits.
void openEmailForReading(
  BuildContext context,
  Email email,
  EmailFolder? selectedFolder,
) {
  context.read<HomeCubit>().selectEmail(email.id);
  context.read<EmailDetailBloc>().add(
        EmailDetailLoadRequested(emailId: email.id),
      );
  // Marking is thread-wide: opening a conversation flips every unread
  // message in it, not just the one shown in the reading pane. This also
  // covers the case where the newest message is already read but an
  // older one in the thread is still unread.
  final unreadIds = unreadThreadEmailIds(context, email);
  if (unreadIds.isNotEmpty) {
    markThreadReadOnceLoaded(context, email, unreadIds, selectedFolder);
  }
}

/// Ids of every unread message that belongs to [email]'s conversation thread
/// (falling back to just [email] itself when it isn't part of a thread or the
/// list state is unavailable). Grouping mirrors the email list panel: messages
/// share a thread when their `conversationId` (or, absent one, their own id)
/// matches.
List<String> unreadThreadEmailIds(BuildContext context, Email email) {
  final listState = context.read<EmailListBloc>().state;
  final threadKey = email.conversationId ?? email.id;
  if (listState is! EmailListLoaded) {
    return email.isRead ? const [] : [email.id];
  }
  return listState.emails
      .where((e) => (e.conversationId ?? e.id) == threadKey && !e.isRead)
      .map((e) => e.id)
      .toList();
}

/// Marks [unreadIds] read only once [email]'s content actually finishes
/// loading, not the instant it's opened. Firing the mark-read/unread-count
/// side effects eagerly meant an unread email that fails to open offline
/// (never cached with a full body, no network to fall back to) got marked
/// read anyway — the user could no longer tell it was still unseen once they
/// went back online, even though they'd never actually read it.
void markThreadReadOnceLoaded(
  BuildContext context,
  Email email,
  List<String> unreadIds,
  EmailFolder? selectedFolder,
) {
  // Counted now, while the rows are still unread, not once the load lands.
  final inboxReads =
      _inboxMessageCount(context, email, unreadIds, selectedFolder);
  context
      .read<EmailDetailBloc>()
      .stream
      .firstWhere((s) => s is EmailDetailLoaded || s is EmailDetailError)
      .then((state) {
    if (state is! EmailDetailLoaded || state.email.id != email.id) return;
    if (!context.mounted) return;
    context.read<EmailListBloc>().add(
          EmailListMarkThreadReadRequested(emailIds: unreadIds, isRead: true),
        );
    if (selectedFolder != null) {
      context.read<FolderListBloc>().add(
            FolderListUnreadCountChanged(
              folderId: selectedFolder.id,
              unreadCountDelta: -unreadIds.length,
            ),
          );
    }
    // The poller's count is the *Inbox's* unread count — it is what the dock
    // badge and the header envelope show — so only the thread's Inbox
    // messages move it, the same rule the delete and move paths apply. It
    // used to decrement once per message read in any folder, and the poller
    // now re-applies a decrement over the next server count it matches, so
    // an Archive read would otherwise hold the Inbox badge one too low.
    final poller = context.read<MailPollerCubit>();
    for (var i = 0; i < inboxReads; i++) {
      poller.decrementUnreadCount();
    }
  });
}

/// How many of [unreadIds] are messages that live in the Inbox.
///
/// A folder listing carries a thread's other-folder messages too (the copies
/// in Sent, already-filed replies), and the user may be reading from any
/// folder, so membership is per message: [Email.isInFolder] against the
/// Inbox's id where the folder list knows it. A row with no folder
/// information at all came straight from the listed folder, so it is in the
/// Inbox exactly when that is the folder being read.
int _inboxMessageCount(
  BuildContext context,
  Email email,
  List<String> unreadIds,
  EmailFolder? selectedFolder,
) {
  final readingInbox = selectedFolder?.displayName.toLowerCase() == 'inbox';
  final folderState = context.read<FolderListBloc>().state;
  final inboxId = folderState is FolderListLoaded
      ? folderState.folders
          .where((f) => f.displayName.toLowerCase() == 'inbox')
          .map((f) => f.id)
          .firstOrNull
      : null;
  final listState = context.read<EmailListBloc>().state;
  final byId = {
    if (listState is EmailListLoaded)
      for (final e in listState.emails) e.id: e,
    email.id: email,
  };
  var count = 0;
  for (final id in unreadIds) {
    final e = byId[id];
    if (e == null) continue;
    final unplaced = e.folderIds.isEmpty && e.parentFolderId == null;
    final inInbox =
        inboxId == null || unplaced ? readingInbox : e.isInFolder(inboxId);
    if (inInbox) count++;
  }
  return count;
}
