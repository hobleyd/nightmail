import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum HomeView { email, calendar, tasks, ai }

class HomeCubit extends Cubit<HomeState> {
  HomeCubit() : super(const HomeState());

  final Map<String, String> _savedFolders = {};
  final Map<String, Set<String>> _savedExpanded = {};

  void rememberFolderForAccount(String accountId, String folderId) {
    _savedFolders[accountId] = folderId;
  }

  String? savedFolderForAccount(String accountId) => _savedFolders[accountId];

  void rememberExpandedForAccount(String accountId, Set<String> ids) {
    _savedExpanded[accountId] = Set.of(ids);
  }

  Set<String> savedExpandedForAccount(String accountId) =>
      Set.of(_savedExpanded[accountId] ?? {});

  void clearFolder() {
    emit(HomeState(view: state.view, accountLabel: state.accountLabel));
  }

  void selectFolder(String folderId) {
    emit(HomeState(
      selectedFolderId: folderId,
      view: state.view,
      accountLabel: state.accountLabel,
    ));
  }

  void selectEmail(String emailId) {
    emit(state.copyWith(selectedEmailId: emailId));
  }

  void clearEmail() {
    emit(state.copyWith(clearEmail: true));
  }

  void showCalendar() {
    emit(state.copyWith(view: HomeView.calendar));
  }

  void showTasks() {
    emit(state.copyWith(view: HomeView.tasks));
  }

  void showAi() {
    emit(state.copyWith(view: HomeView.ai));
  }

  void showEmail() {
    emit(state.copyWith(view: HomeView.email));
  }

  void setAccountLabel(String label) {
    emit(state.copyWith(accountLabel: label));
  }
}

class HomeState extends Equatable {
  const HomeState({
    this.selectedFolderId,
    this.selectedEmailId,
    this.view = HomeView.email,
    this.accountLabel = '',
  });

  final String? selectedFolderId;
  final String? selectedEmailId;
  final HomeView view;

  /// Display name of the active account (shown in folder panel header).
  final String accountLabel;

  HomeState copyWith({
    String? selectedFolderId,
    String? selectedEmailId,
    bool clearEmail = false,
    HomeView? view,
    String? accountLabel,
  }) {
    return HomeState(
      selectedFolderId: selectedFolderId ?? this.selectedFolderId,
      selectedEmailId:
          clearEmail ? null : (selectedEmailId ?? this.selectedEmailId),
      view: view ?? this.view,
      accountLabel: accountLabel ?? this.accountLabel,
    );
  }

  @override
  List<Object?> get props => [selectedFolderId, selectedEmailId, view, accountLabel];
}
