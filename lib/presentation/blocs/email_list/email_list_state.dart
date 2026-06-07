import 'package:equatable/equatable.dart';

import '../../../domain/entities/email.dart';

sealed class EmailListState extends Equatable {
  const EmailListState();

  @override
  List<Object?> get props => [];
}

final class EmailListInitial extends EmailListState {
  const EmailListInitial();
}

final class EmailListLoading extends EmailListState {
  const EmailListLoading();
}

final class EmailListLoaded extends EmailListState {
  const EmailListLoaded({
    required this.emails,
    this.hasMore = true,
    this.isLoadingMore = false,
    this.isLoadingFresh = false,
    this.currentFolderId,
    this.expandedConversationIds = const {},
    this.emptyingFolderIds = const {},
  });

  final List<Email> emails;
  final bool hasMore;
  final bool isLoadingMore;

  /// True while cached emails are shown and a background network refresh
  /// is still in-flight. Clears to false once the network call completes
  /// (successfully or not).
  final bool isLoadingFresh;

  final String? currentFolderId;
  final Set<String> expandedConversationIds;

  /// Folder IDs for which a Delete All operation is currently in flight.
  final Set<String> emptyingFolderIds;

  EmailListLoaded copyWith({
    List<Email>? emails,
    bool? hasMore,
    bool? isLoadingMore,
    bool? isLoadingFresh,
    String? currentFolderId,
    Set<String>? expandedConversationIds,
    Set<String>? emptyingFolderIds,
  }) {
    return EmailListLoaded(
      emails: emails ?? this.emails,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      isLoadingFresh: isLoadingFresh ?? this.isLoadingFresh,
      currentFolderId: currentFolderId ?? this.currentFolderId,
      expandedConversationIds: expandedConversationIds ?? this.expandedConversationIds,
      emptyingFolderIds: emptyingFolderIds ?? this.emptyingFolderIds,
    );
  }

  @override
  List<Object?> get props => [
        emails,
        hasMore,
        isLoadingMore,
        isLoadingFresh,
        currentFolderId,
        expandedConversationIds,
        emptyingFolderIds,
      ];
}

final class EmailListError extends EmailListState {
  const EmailListError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
