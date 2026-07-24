import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/todo_task.dart';
import '../../domain/entities/todo_task_attachment.dart';
import '../../domain/entities/todo_task_list.dart';
import '../../domain/repositories/tasks_repository.dart';
import '../../infrastructure/accounts/account_manager.dart';

class TasksRepositoryImpl implements TasksRepository {
  const TasksRepositoryImpl({required this._accountManager});

  final AccountManager _accountManager;

  @override
  Future<Either<Failure, List<TodoTaskList>>> getTaskLists() async {
    final ds = _accountManager.tasksDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Tasks are not available for this account type'),
      );
    }
    try {
      final lists = await ds.getTaskLists();
      return Right(List<TodoTaskList>.from(lists));
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, List<TodoTask>>> getTasks(
    String listId, {
    bool includeCompleted = false,
  }) async {
    final ds = _accountManager.tasksDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Tasks are not available for this account type'),
      );
    }
    try {
      final tasks =
          await ds.getTasks(listId, includeCompleted: includeCompleted);
      return Right(List<TodoTask>.from(tasks));
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, TodoTask>> createTask({
    required String listId,
    required String title,
    String? body,
    DateTime? dueDate,
    TodoTaskImportance importance = TodoTaskImportance.normal,
  }) async {
    final ds = _accountManager.tasksDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Tasks are not available for this account type'),
      );
    }
    try {
      final task = await ds.createTask(
        listId: listId,
        title: title,
        body: body,
        dueDate: dueDate,
        importance: importance,
      );
      return Right(task);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, TodoTask>> updateTaskStatus({
    required String listId,
    required String taskId,
    required TodoTaskStatus status,
  }) async {
    final ds = _accountManager.tasksDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Tasks are not available for this account type'),
      );
    }
    try {
      final task = await ds.updateTaskStatus(
        listId: listId,
        taskId: taskId,
        status: status,
      );
      return Right(task);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, TodoTask>> updateTaskDueDate({
    required String listId,
    required String taskId,
    required DateTime? dueDate,
  }) async {
    return _withDatasource((ds) => ds.updateTaskDueDate(
          listId: listId,
          taskId: taskId,
          dueDate: dueDate,
        ));
  }

  @override
  Future<Either<Failure, TodoTaskAttachment>> attachEmailToTask({
    required String listId,
    required String taskId,
    required String fileName,
    required Uint8List emlBytes,
  }) async {
    return _withDatasource((ds) => ds.attachEmailToTask(
          listId: listId,
          taskId: taskId,
          fileName: fileName,
          emlBytes: emlBytes,
        ));
  }

  @override
  Future<Either<Failure, TodoTask>> appendEmailLink({
    required String listId,
    required String taskId,
    required String emailId,
  }) async {
    return _withDatasource((ds) => ds.appendEmailLinkToNotes(
          listId: listId,
          taskId: taskId,
          emailId: emailId,
        ));
  }

  @override
  Future<Either<Failure, List<TodoTaskAttachment>>> getTaskAttachments({
    required String listId,
    required String taskId,
  }) async {
    return _withDatasource((ds) async {
      final models = await ds.getTaskAttachments(listId: listId, taskId: taskId);
      return List<TodoTaskAttachment>.from(models);
    });
  }

  @override
  Future<Either<Failure, Uint8List>> downloadTaskAttachment({
    required String listId,
    required String taskId,
    required String attachmentId,
  }) async {
    return _withDatasource((ds) => ds.downloadTaskAttachment(
          listId: listId,
          taskId: taskId,
          attachmentId: attachmentId,
        ));
  }

  Future<Either<Failure, T>> _withDatasource<T>(
    Future<T> Function(dynamic ds) fn,
  ) async {
    final ds = _accountManager.tasksDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Tasks are not available for this account type'),
      );
    }
    try {
      return Right(await fn(ds));
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }
}
