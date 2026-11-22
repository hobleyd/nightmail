import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/cloud_file.dart';
import '../../../domain/usecases/cloud_files.dart';
import '../../../infrastructure/accounts/account_manager.dart';

class CloudFilePickerState extends Equatable {
  const CloudFilePickerState({
    this.sources = const [],
    this.loadingSources = true,
    this.accountId,
    this.collection = CloudFileCollection.myFiles,
    this.path = const [],
    this.query = '',
    this.items = const [],
    this.loading = false,
    this.error,
    this.selected = const [],
    this.granting = false,
  });

  final List<CloudFileSource> sources;
  final bool loadingSources;

  /// The account being browsed, and which of its collections.
  final String? accountId;
  final CloudFileCollection collection;

  /// The folders opened below [collection]'s top, outermost first.
  final List<CloudFile> path;

  /// Non-empty while showing search results instead of [path]'s folder.
  final String query;

  final List<CloudFile> items;
  final bool loading;
  final String? error;

  /// Picked files, in the order they were picked. Kept across folders, so a
  /// sender can gather files from several places in one go.
  final List<CloudFile> selected;

  /// An access grant (a browser sign-in) is under way.
  final bool granting;

  CloudFileSource? get source {
    for (final s in sources) {
      if (s.accountId == accountId) return s;
    }
    return null;
  }

  bool get searching => query.isNotEmpty;

  CloudFilePickerState copyWith({
    List<CloudFileSource>? sources,
    bool? loadingSources,
    String? accountId,
    CloudFileCollection? collection,
    List<CloudFile>? path,
    String? query,
    List<CloudFile>? items,
    bool? loading,
    String? Function()? error,
    List<CloudFile>? selected,
    bool? granting,
  }) =>
      CloudFilePickerState(
        sources: sources ?? this.sources,
        loadingSources: loadingSources ?? this.loadingSources,
        accountId: accountId ?? this.accountId,
        collection: collection ?? this.collection,
        path: path ?? this.path,
        query: query ?? this.query,
        items: items ?? this.items,
        loading: loading ?? this.loading,
        error: error != null ? error() : this.error,
        selected: selected ?? this.selected,
        granting: granting ?? this.granting,
      );

  @override
  List<Object?> get props => [
        sources,
        loadingSources,
        accountId,
        collection,
        path,
        query,
        items,
        loading,
        error,
        selected,
        granting,
      ];
}

/// Drives the compose window's cloud file picker: which account and folder is
/// showing, the search, and what has been picked.
class CloudFilePickerCubit extends Cubit<CloudFilePickerState> {
  CloudFilePickerCubit({
    required this._accountManager,
    required this._listFiles,
    required this._searchFiles,
    this.preferredAccountId,
  }) : super(const CloudFilePickerState());

  final AccountManager _accountManager;
  final ListCloudFiles _listFiles;
  final SearchCloudFiles _searchFiles;

  /// The account the message is being sent from — browsed first when it has
  /// a drive, since that is where the sender's own files most likely are.
  final String? preferredAccountId;

  /// Bumped by every navigation, so a slow listing that lands after the
  /// sender has moved on is dropped rather than shown in the wrong folder.
  int _generation = 0;

  Future<void> load() async {
    final sources = await _accountManager.cloudFileSources();
    if (isClosed) return;
    final first = sources.where((s) => s.accountId == preferredAccountId)
            .firstOrNull ??
        sources.firstOrNull;
    emit(state.copyWith(sources: sources, loadingSources: false));
    if (first != null) await selectSource(first.accountId);
  }

  Future<void> selectSource(String accountId,
      [CloudFileCollection collection = CloudFileCollection.myFiles]) async {
    emit(state.copyWith(
      accountId: accountId,
      collection: collection,
      path: const [],
      query: '',
    ));
    await _refresh();
  }

  Future<void> openFolder(CloudFile folder) async {
    emit(state.copyWith(path: [...state.path, folder], query: ''));
    await _refresh();
  }

  /// Goes back to the [depth]th folder of the breadcrumb (0 is the top of the
  /// collection).
  Future<void> goTo(int depth) async {
    emit(state.copyWith(path: state.path.take(depth).toList(), query: ''));
    await _refresh();
  }

  Future<void> search(String query) async {
    emit(state.copyWith(query: query.trim()));
    await _refresh();
  }

  void toggle(CloudFile file) {
    final selected = [...state.selected];
    if (!selected.remove(file)) selected.add(file);
    emit(state.copyWith(selected: selected));
  }

  Future<void> retry() => _refresh();

  /// Runs the browser sign-in that grants read access to the current
  /// account's files, then lists them. Returns false when the sender declined
  /// or the sign-in failed (with [CloudFilePickerState.error] saying so).
  Future<bool> grantAccess() async {
    final accountId = state.accountId;
    if (accountId == null) return false;
    emit(state.copyWith(granting: true, error: () => null));
    try {
      final granted = await _accountManager.requestCloudDriveAccess(accountId);
      final sources = await _accountManager.cloudFileSources();
      if (isClosed) return granted;
      emit(state.copyWith(
        sources: sources,
        granting: false,
        error: () => granted ? null : 'Access was not granted',
      ));
      if (granted) await _refresh();
      return granted;
    } catch (e) {
      if (!isClosed) {
        emit(state.copyWith(
            granting: false, error: () => 'Could not grant access: $e'));
      }
      return false;
    }
  }

  Future<void> _refresh() async {
    final source = state.source;
    if (source == null || !source.hasReadAccess) {
      emit(state.copyWith(items: const [], loading: false, error: () => null));
      return;
    }
    final generation = ++_generation;
    emit(state.copyWith(loading: true, error: () => null));
    final result = state.searching
        ? await _searchFiles(source.accountId, state.query)
        : await _listFiles(
            source.accountId,
            folder: state.path.lastOrNull,
            collection: state.collection,
          );
    if (isClosed || generation != _generation) return;
    result.match(
      (failure) => emit(state.copyWith(
        items: const [],
        loading: false,
        error: () => _describe(failure),
      )),
      (items) => emit(state.copyWith(items: items, loading: false)),
    );
  }

  String _describe(Failure failure) => switch (failure) {
        NetworkFailure() => "You're offline — couldn't list the files",
        AuthFailure() =>
          'This account needs to sign in again before its files can be listed',
        ServerFailure(statusCode: 501) =>
          'This server does not offer that list of files',
        _ => failure.message,
      };
}
