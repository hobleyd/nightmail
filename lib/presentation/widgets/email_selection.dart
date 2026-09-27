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
    final poller = context.read<MailPollerCubit>();
    for (var i = 0; i < unreadIds.length; i++) {
      poller.decrementUnreadCount();
    }
  });
}
