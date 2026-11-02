import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_event.dart';
import '../blocs/folder_list/folder_list_state.dart';
import '../blocs/mail_poller/mail_poller_cubit.dart';

/// The folder-panel and badge deltas for [moved] leaving [sourceFolderId] for
/// [destination], applied alongside an `EmailListEmailsMoved` — by a drop on
/// the folder panel and by the touch selection's Move.
///
/// The poller's count is the Inbox's, so it moves only when the move crosses
/// the Inbox boundary.
void applyEmailMoveCounts(
  BuildContext context, {
  required List<Email> moved,
  required String? sourceFolderId,
  required EmailFolder destination,
}) {
  if (moved.isEmpty ||
      sourceFolderId == null ||
      sourceFolderId == destination.id) {
    return;
  }
  final unreadMoved = moved.where((e) => !e.isRead).length;
  final folderListBloc = context.read<FolderListBloc>();
  folderListBloc.add(FolderListUnreadCountChanged(
    folderId: sourceFolderId,
    unreadCountDelta: -unreadMoved,
    totalCountDelta: -moved.length,
  ));
  folderListBloc.add(FolderListUnreadCountChanged(
    folderId: destination.id,
    unreadCountDelta: unreadMoved,
    totalCountDelta: moved.length,
  ));
  if (unreadMoved == 0) return;
  final folderListState = folderListBloc.state;
  final sourceFolder = folderListState is FolderListLoaded
      ? folderListState.folders
          .where((f) => f.id == sourceFolderId)
          .firstOrNull
      : null;
  final sourceIsInbox = sourceFolder?.displayName.toLowerCase() == 'inbox';
  final destIsInbox = destination.displayName.toLowerCase() == 'inbox';
  final mailPoller = context.read<MailPollerCubit>();
  if (sourceIsInbox && !destIsInbox) {
    for (var i = 0; i < unreadMoved; i++) {
      mailPoller.decrementUnreadCount();
    }
  } else if (destIsInbox && !sourceIsInbox) {
    for (var i = 0; i < unreadMoved; i++) {
      mailPoller.incrementUnreadCount();
    }
  }
}
