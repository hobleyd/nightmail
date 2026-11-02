import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

/// A message's raw RFC 822 source — the bytes of its `.eml` — for forwarding
/// it as an attachment.
class GetRawEmailBytes implements UseCase<Uint8List, String> {
  const GetRawEmailBytes(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Uint8List>> call(String emailId) =>
      _repository.getRawEmailBytes(emailId);
}
