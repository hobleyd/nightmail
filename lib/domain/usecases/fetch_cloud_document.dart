import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/cloud_document.dart';
import '../repositories/cloud_drive_repository.dart';

class FetchCloudDocument implements UseCase<CloudDocument, CloudDocumentLink> {
  const FetchCloudDocument(this._repository);

  final CloudDriveRepository _repository;

  @override
  Future<Either<Failure, CloudDocument>> call(CloudDocumentLink params) =>
      _repository.fetchDocument(params);
}
