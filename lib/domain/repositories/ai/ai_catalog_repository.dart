import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../entities/ai/ai_model.dart';
import '../../entities/ai/ai_provider.dart';

/// Source of truth for "what AI backends exist and what can they do".
///
/// Fetches the [models.dev](https://models.dev) catalog and merges it with the
/// user's BYO providers, caching the last good fetch as a cold-start fallback.
/// Reads follow a **stale-while-revalidate** policy: the in-memory / cached
/// catalog is served immediately while a background refresh runs.
abstract interface class AiCatalogRepository {
  /// All known providers — catalog ∪ user BYO entries, each `source`-tagged.
  ///
  /// Serves the in-memory (or cold-start blob) catalog immediately. When
  /// [forceRefresh] is `true` the returned future awaits a fresh fetch from
  /// models.dev before completing; otherwise a refresh is kicked off in the
  /// background and the cached snapshot is returned.
  ///
  /// Fails with [CatalogUnavailable] only when the network fetch fails and no
  /// cache exists.
  Future<Either<Failure, List<AiProvider>>> getProviders({
    bool forceRefresh = false,
  });

  /// A single provider by its catalog (or synthetic BYO) id.
  Future<Either<Failure, AiProvider>> getProvider(String providerId);

  /// The models offered by [providerId].
  Future<Either<Failure, List<AiModel>>> getModelsForProvider(
    String providerId,
  );

  /// Model ids a provider advertises *live* at its own `/models` endpoint.
  ///
  /// For BYO / self-hosted servers (e.g. Ollama) that are not in the static
  /// catalog, so the UI can present a real dropdown rather than a free-text box.
  /// Fails (left) when the endpoint cannot be reached; callers should fall back
  /// to manual model entry.
  Future<Either<Failure, List<String>>> listLiveModels({
    required String baseUrl,
    String? apiKey,
    bool azure = false,
  });

  /// A single model identified by `(providerId, modelId)`.
  Future<Either<Failure, AiModel>> getModel({
    required String providerId,
    required String modelId,
  });

  /// Forces a foreground refresh from models.dev, updating the cold-start blob.
  ///
  /// Fails with [CatalogUnavailable] when the fetch fails.
  Future<Either<Failure, Unit>> refreshCatalog();
}
