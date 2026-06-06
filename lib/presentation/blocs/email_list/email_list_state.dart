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
    this.currentFolderId,
    this.expandedConversationIds = const {},
  });

  final List<Email> emails;
  final bool hasMore;
  final bool isLoadingMore;
  final String? currentFolderId;
  final Set<String> expandedConversationIds;

  EmailListLoaded copyWith({
    List<Email>? emails,
    bool? hasMore,
    bool? isLoadingMore,
    String? currentFolderId,
    Set<String>? expandedConversationIds,
  }) {
    return EmailListLoaded(
      emails: emails ?? this.emails,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      currentFolderId: currentFolderId ?? this.currentFolderId,
      expandedConversationIds: expandedConversationIds ?? this.expandedConversationIds,
    );
  }

  @override
  List<Object?> get props => [emails, hasMore, isLoadingMore, currentFolderId, expandedConversationIds];
}

final class EmailListError extends EmailListState {
  const EmailListError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
