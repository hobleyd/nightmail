import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class HomeCubit extends Cubit<HomeState> {
  HomeCubit() : super(const HomeState());

  void selectFolder(String folderId) {
    emit(HomeState(selectedFolderId: folderId));
  }

  void selectEmail(String emailId) {
    emit(state.copyWith(selectedEmailId: emailId));
  }

  void clearEmail() {
    emit(state.copyWith(clearEmail: true));
  }
}

class HomeState extends Equatable {
  const HomeState({this.selectedFolderId, this.selectedEmailId});

  final String? selectedFolderId;
  final String? selectedEmailId;

  HomeState copyWith({
    String? selectedFolderId,
    String? selectedEmailId,
    bool clearEmail = false,
  }) {
    return HomeState(
      selectedFolderId: selectedFolderId ?? this.selectedFolderId,
      selectedEmailId: clearEmail ? null : (selectedEmailId ?? this.selectedEmailId),
    );
  }

  @override
  List<Object?> get props => [selectedFolderId, selectedEmailId];
}
