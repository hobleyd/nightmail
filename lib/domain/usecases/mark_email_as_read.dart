import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../repositories/email_repository.dart';

class MarkEmailAsRead implements UseCase<Email, MarkEmailAsReadParams> {
  const MarkEmailAsRead(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Email>> call(MarkEmailAsReadParams params) {
    return _repository.markAsRead(id: params.id, isRead: params.isRead);
  }
}

class MarkEmailAsReadParams extends Equatable {
  const MarkEmailAsReadParams({required this.id, required this.isRead});

  final String id;
  final bool isRead;

  @override
  List<Object?> get props => [id, isRead];
}
