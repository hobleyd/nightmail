import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../repositories/email_repository.dart';

class SearchEmails implements UseCase<List<Email>, SearchEmailsParams> {
  const SearchEmails(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, List<Email>>> call(SearchEmailsParams params) {
    return _repository.searchEmails(
      folderId: params.folderId,
      query: params.query,
      top: params.top,
    );
  }
}

class SearchEmailsParams extends Equatable {
  const SearchEmailsParams({
    this.folderId,
    required this.query,
    this.top = 50,
  });

  final String? folderId;
  final String query;
  final int top;

  @override
  List<Object?> get props => [folderId, query, top];
}
