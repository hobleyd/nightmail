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
    this.currentFolderName,
    this.expandedConversationIds = const {},
    this.emptyingFolderIds = const {},
    this.spamEmailIds = const {},
    this.isSearchMode = false,
    this.activeSearchQuery,
    this.focusedThreadId,
    this.focusedThreadSubject,
  });

  final List<Email> emails;
  final bool hasMore;
  final bool isLoadingMore;

  /// True while cached emails are shown and a background network refresh
  /// is still in-flight. Clears to false once the network call completes
  /// (successfully or not).
  final bool isLoadingFresh;

  final String? currentFolderId;
  final String? currentFolderName;
  final Set<String> expandedConversationIds;

  /// Folder IDs for which a Delete All operation is currently in flight.
  final Set<String> emptyingFolderIds;

  /// IDs of emails the Bayesian spam filter has classified as spam (IMAP only).
  final Set<String> spamEmailIds;

  /// True when the search bar is visible (before or after a search is run).
  final bool isSearchMode;

  /// Non-null while search results are being displayed.
  final String? activeSearchQuery;

  /// Non-null while [emails] holds a single conversation thread rather than
  /// the folder's contents. Background repaints leave this view alone.
  final String? focusedThreadId;

  /// Subject of the focused thread, for the header banner.
  final String? focusedThreadSubject;

  /// True when [emails] is something other than the current folder's listing,
  /// so handlers that repaint from the folder know to stand down.
  bool get isShowingFolder => activeSearchQuery == null && focusedThreadId == null;

  static const _unset = Object();

  EmailListLoaded copyWith({
    List<Email>? emails,
    bool? hasMore,
    bool? isLoadingMore,
    bool? isLoadingFresh,
    String? currentFolderId,
    Set<String>? expandedConversationIds,
    Set<String>? emptyingFolderIds,
    Set<String>? spamEmailIds,
    bool? isSearchMode,
    Object? activeSearchQuery = _unset,
    Object? focusedThreadId = _unset,
    Object? focusedThreadSubject = _unset,
  }) {
    return EmailListLoaded(
      emails: emails ?? this.emails,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      isLoadingFresh: isLoadingFresh ?? this.isLoadingFresh,
      currentFolderId: currentFolderId ?? this.currentFolderId,
      currentFolderName: currentFolderName,
      expandedConversationIds: expandedConversationIds ?? this.expandedConversationIds,
      emptyingFolderIds: emptyingFolderIds ?? this.emptyingFolderIds,
      spamEmailIds: spamEmailIds ?? this.spamEmailIds,
      isSearchMode: isSearchMode ?? this.isSearchMode,
      activeSearchQuery: identical(activeSearchQuery, _unset)
          ? this.activeSearchQuery
          : activeSearchQuery as String?,
      focusedThreadId: identical(focusedThreadId, _unset)
          ? this.focusedThreadId
          : focusedThreadId as String?,
      focusedThreadSubject: identical(focusedThreadSubject, _unset)
          ? this.focusedThreadSubject
          : focusedThreadSubject as String?,
    );
  }

  @override
  List<Object?> get props => [
        emails,
        hasMore,
        isLoadingMore,
        isLoadingFresh,
        currentFolderId,
        currentFolderName,
        expandedConversationIds,
        emptyingFolderIds,
        spamEmailIds,
        isSearchMode,
        activeSearchQuery,
        focusedThreadId,
        focusedThreadSubject,
      ];
}

final class EmailListError extends EmailListState {
  const EmailListError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
