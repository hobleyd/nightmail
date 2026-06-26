import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/ai/ai_model.dart';
import '../../../domain/entities/ai/ai_provider.dart';
import '../../../domain/repositories/ai/ai_catalog_repository.dart';
import '../../datasources/ai/ai_provider_registry.dart';
import '../../datasources/ai/provider_models_datasource.dart';

/// Thin [AiCatalogRepository] over the in-memory [AiProviderRegistry].
///
/// The registry is the single source of truth for "what backends exist"
/// (catalog ∪ user BYO). This impl adds the domain's `Either<Failure, T>`
/// boundary and the stale-while-revalidate read policy: every read first asks
/// the registry to (re)load, then serves whatever it holds.
///
/// A network failure during a background-style load is **tolerated** — as long
/// as the registry can serve an in-memory snapshot or its cold-start blob, the
/// cached catalog is returned. [CatalogUnavailable] is surfaced **only** when
/// nothing at all can be served (no cache exists). The single exception is
/// [refreshCatalog], a foreground refresh whose fetch failure is reported.
class AiCatalogRepositoryImpl implements AiCatalogRepository {
  const AiCatalogRepositoryImpl({
    required AiProviderRegistry registry,
    required ProviderModelsDatasource providerModels,
  })  : _registry = registry,
        _providerModels = providerModels;

  final AiProviderRegistry _registry;
  final ProviderModelsDatasource _providerModels;

  static const CatalogUnavailable _unavailable = CatalogUnavailable(
    message: 'The AI model catalog is unavailable and no cached copy exists.',
  );

  @override
  Future<Either<Failure, List<AiProvider>>> getProviders({
    bool forceRefresh = false,
  }) async {
    await _tryLoad(forceRefresh: forceRefresh);
    final providers = _registry.all();
    if (providers.isEmpty) return const Left(_unavailable);
    return Right(providers);
  }

  @override
  Future<Either<Failure, AiProvider>> getProvider(String providerId) async {
    await _tryLoad();
    if (_registry.all().isEmpty) return const Left(_unavailable);

    final provider = _registry.byId(providerId);
    if (provider == null) {
      return Left(
        CacheFailure(message: 'AI provider "$providerId" not found in catalog.'),
      );
    }
    return Right(provider);
  }

  @override
  Future<Either<Failure, List<AiModel>>> getModelsForProvider(
    String providerId,
  ) async {
    await _tryLoad();
    if (_registry.all().isEmpty) return const Left(_unavailable);

    if (_registry.byId(providerId) == null) {
      return Left(
        CacheFailure(message: 'AI provider "$providerId" not found in catalog.'),
      );
    }
    return Right(_registry.modelsFor(providerId));
  }

  @override
  Future<Either<Failure, List<String>>> listLiveModels({
    required String baseUrl,
    String? apiKey,
    bool azure = false,
  }) async {
    if (baseUrl.trim().isEmpty) return const Right(<String>[]);
    try {
      final ids = await _providerModels.list(
        baseUrl: baseUrl,
        apiKey: apiKey,
        azure: azure,
      );
      return Right(ids);
    } catch (e) {
      return Left(
        ProviderUnreachable(
          message: 'Could not list models from $baseUrl: $e',
        ),
      );
    }
  }

  @override
  Future<Either<Failure, AiModel>> getModel({
    required String providerId,
    required String modelId,
  }) async {
    await _tryLoad();
    if (_registry.all().isEmpty) return const Left(_unavailable);

    AiModel? match;
    for (final model in _registry.modelsFor(providerId)) {
      if (model.id == modelId) {
        match = model;
        break;
      }
    }
    if (match == null) {
      return Left(
        CacheFailure(
          message:
              'AI model "$modelId" not found for provider "$providerId".',
        ),
      );
    }
    return Right(match);
  }

  @override
  Future<Either<Failure, Unit>> refreshCatalog() async {
    // Foreground refresh: unlike the reads above, a fetch failure here is
    // reported rather than tolerated (per the repository contract).
    try {
      await _registry.load(forceRefresh: true);
      return const Right(unit);
    } catch (_) {
      return const Left(
        CatalogUnavailable(
          message: 'Failed to refresh the AI catalog from models.dev.',
        ),
      );
    }
  }

  /// Asks the registry to (re)load, swallowing failures so a stale in-memory /
  /// cold-start catalog can still be served. Callers detect the "no cache at
  /// all" case via [AiProviderRegistry.all] being empty.
  Future<void> _tryLoad({bool forceRefresh = false}) async {
    try {
      await _registry.load(forceRefresh: forceRefresh);
    } catch (_) {
      // Tolerated — fall back to whatever the registry already holds.
    }
  }
}
