import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../domain/entities/ai/ai_model.dart';
import '../../../domain/entities/ai/ai_provider.dart';
import 'ai_catalog_cache_datasource.dart';
import 'ai_config_datasource.dart';
import 'models_dev_catalog_datasource.dart';

/// The single source of truth for "what AI backends exist and what can they do".
///
/// Registered as a `get_it` lazy singleton. Holds the models.dev catalog
/// (a `List<AiProvider>`, each carrying its own `List<AiModel>`) **in memory**
/// for the lifetime of the session — filtering/sorting a few thousand entries
/// in Dart is instant, so no SQL is involved on the read path.
///
/// Catalog data is *reference data*: it is fetched from upstream and cached as a
/// single raw-JSON blob, never mirrored row-by-row into drift. The durable rows
/// come from [AiConfigDatasource.getConfiguredProviders] and cover **both** the
/// user's own BYO providers (`source == AiProviderSource.user`) *and* catalog
/// picks the user has configured with their own endpoint (e.g. an Azure resource
/// URL). Both kinds are merged over the in-memory catalog by [all].
///
/// ## Stale-while-revalidate
///
/// [load] serves whatever is already available immediately and revalidates from
/// the network in the background:
///
/// * **Warm** (already loaded this session) → serve in-memory, kick a background
///   refresh.
/// * **Cold with a cache blob** (e.g. offline launch) → parse the blob for an
///   instant catalog, then refresh in the background.
/// * **Cold with no blob** (first ever launch) → there is nothing to serve, so
///   block on the network fetch.
///
/// A successful fetch replaces the in-memory catalog and rewrites the cache blob.
/// Failures are swallowed (logged via [debugPrint]); callers surface
/// `CatalogUnavailable` only when the catalog ends up empty.
///
/// ## Collaborator contracts
///
/// These types live in the sibling datasource files. The registry depends only
/// on this minimal surface:
///
/// * [ModelsDevCatalogDatasource]
///   * `Future<Map<String, dynamic>> fetchRaw()` — unconditional network fetch
///     of the upstream catalog JSON. (Conditional/etag fetch — sending
///     `If-None-Match`/`If-Modified-Since` and handling `304` — is reserved for
///     a future slice and **not yet implemented**; the cache's etag/lastModified
///     columns are currently unused.)
///   * `List<AiProvider> parse(String rawJson)` — parse a raw blob (cold-start
///     and post-fetch).
/// * [AiCatalogCacheDatasource]
///   * `Future<CachedCatalog?> read()` — `CachedCatalog` exposes `rawJson` and
///     `fetchedAt`.
///   * `Future<void> write({required String rawJson, required DateTime
///     fetchedAt})`.
/// * [AiConfigDatasource]
///   * `Future<List<AiProvider>> getConfiguredProviders()` — durable providers
///     (BYO *and* configured catalog picks), each `source`-tagged.
/// * [AiProvider] exposes `id`, `kind` ([AiProviderKind]), `source`,
///   `requiresApiKey` and `models` (`List<AiModel>`).
class AiProviderRegistry {
  AiProviderRegistry({
    required ModelsDevCatalogDatasource catalogDatasource,
    required AiCatalogCacheDatasource cacheDatasource,
    required AiConfigDatasource configDatasource,
  })  : _catalog = catalogDatasource,
        _cache = cacheDatasource,
        _config = configDatasource;

  final ModelsDevCatalogDatasource _catalog;
  final AiCatalogCacheDatasource _cache;
  final AiConfigDatasource _config;

  /// Catalog providers (source == catalog), held in memory for the session.
  List<AiProvider> _catalogProviders = const [];

  /// Durable configured providers (BYO *and* catalog picks). Catalog picks may
  /// carry a user-supplied endpoint (e.g. an Azure resource URL) that overlays
  /// the catalog descriptor.
  List<AiProvider> _configuredProviders = const [];

  /// True once the catalog has been populated (from network or cache) at least
  /// once this session.
  bool _loaded = false;

  /// Dedupes overlapping background refreshes onto a single in-flight future.
  Future<void>? _inFlightRefresh;

  /// Whether a usable catalog is currently held in memory.
  bool get isLoaded => _loaded;

  // ---------------------------------------------------------------------------
  // Loading (stale-while-revalidate)
  // ---------------------------------------------------------------------------

  /// Populates the in-memory catalog, serving cached/in-memory data immediately
  /// and revalidating from the network in the background.
  ///
  /// Pass [forceRefresh] to block on a fresh network fetch (e.g. a user-driven
  /// "refresh catalog" action).
  Future<void> load({bool forceRefresh = false}) async {
    await _loadConfiguredProviders();

    if (forceRefresh) {
      await _refreshFromNetwork();
      return;
    }

    if (_loaded) {
      // Warm: serve what we have, revalidate out of band.
      unawaited(_refreshFromNetwork());
      return;
    }

    // Cold start: parse the cache blob for an instant catalog when present.
    final servedFromCache = await _loadFromCache();
    if (servedFromCache) {
      unawaited(_refreshFromNetwork());
    } else {
      // Nothing to serve — block on the network so the first launch works.
      await _refreshFromNetwork();
    }
  }

  Future<void> _loadConfiguredProviders() async {
    try {
      _configuredProviders = await _config.getConfiguredProviders();
    } catch (e) {
      debugPrint('AiProviderRegistry: failed to load configured providers: $e');
    }
  }

  /// Parses the cold-start cache blob into the in-memory catalog.
  /// Returns true when a usable catalog was loaded.
  Future<bool> _loadFromCache() async {
    try {
      final cached = await _cache.read();
      if (cached == null) return false;
      _catalogProviders = _catalog.parse(cached.rawJson);
      _loaded = true;
      return true;
    } catch (e) {
      debugPrint('AiProviderRegistry: failed to parse catalog cache: $e');
      return false;
    }
  }

  /// Conditionally fetches the catalog from upstream and, on success, replaces
  /// the in-memory catalog and rewrites the cache blob. Never throws.
  Future<void> _refreshFromNetwork() {
    return _inFlightRefresh ??=
        _doRefresh().whenComplete(() => _inFlightRefresh = null);
  }

  Future<void> _doRefresh() async {
    try {
      final raw = await _catalog.fetchRaw();
      final rawJson = jsonEncode(raw);

      _catalogProviders = _catalog.parse(rawJson);
      _loaded = true;
      await _cache.write(
        rawJson: rawJson,
        fetchedAt: DateTime.now(),
      );
    } catch (e) {
      debugPrint('AiProviderRegistry: catalog refresh failed: $e');
      // Keep whatever we have; fall back to the cache blob if still empty.
      if (!_loaded) await _loadFromCache();
    }
  }

  /// Ensures [byId]/[all] can answer correctly for a read (e.g. an inference
  /// call) that may happen without the settings screen having (re)loaded.
  ///
  /// Re-reads the cheap, drift-backed user BYO providers on *every* call so a
  /// provider added moments ago is immediately resolvable, and performs a
  /// one-time cold load of the catalog when it has never been populated this
  /// session (cache blob first, network only if there is no blob). Never throws.
  Future<void> ensureReady() async {
    await _loadConfiguredProviders();
    if (!_loaded) {
      final servedFromCache = await _loadFromCache();
      if (!servedFromCache) await _refreshFromNetwork();
    }
  }

  // ---------------------------------------------------------------------------
  // Query API (synchronous — catalog is in memory)
  //
  // Deferred per first slice: the spec's `forCapability(...)` query helper and
  // the `installHint` provider metadata are intentionally not implemented yet;
  // they are convenience surface with no current caller.
  // ---------------------------------------------------------------------------

  /// All known providers: catalog providers unioned with user BYO providers.
  ///
  /// Ordering follows the catalog; user entries with a brand-new id are appended,
  /// while a user entry sharing a catalog id overrides it in place (user wins).
  /// Every entry remains `source`-tagged by its originating datasource.
  List<AiProvider> all() {
    final merged = <String, AiProvider>{};
    for (final provider in _catalogProviders) {
      merged[provider.id] = provider;
    }
    for (final cfg in _configuredProviders) {
      final base = merged[cfg.id];
      if (base != null) {
        // Configured catalog provider: overlay the user-supplied endpoint onto
        // the richer catalog descriptor (keeping its models), so e.g. an Azure
        // catalog pick resolves to the user's per-resource URL.
        final hasUrl = cfg.apiBaseUrl != null && cfg.apiBaseUrl!.isNotEmpty;
        merged[cfg.id] = hasUrl ? base.copyWith(apiBaseUrl: cfg.apiBaseUrl) : base;
      } else {
        merged[cfg.id] = cfg; // BYO provider not present in the catalog.
      }
    }
    return List.unmodifiable(merged.values);
  }

  /// The provider with [id], or null if unknown.
  AiProvider? byId(String id) {
    for (final provider in all()) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  /// All providers of the given privacy [kind] (cloud / local / selfHosted).
  List<AiProvider> byKind(AiProviderKind kind) {
    return List.unmodifiable(all().where((p) => p.kind == kind));
  }

  /// The models offered by provider [providerId] (empty when unknown).
  List<AiModel> modelsFor(String providerId) {
    final provider = byId(providerId);
    if (provider == null) return const [];
    return List.unmodifiable(provider.models);
  }

  // ---------------------------------------------------------------------------
  // Availability
  // ---------------------------------------------------------------------------

  /// Whether the provider requires an API key (derived from its `env` vars).
  /// Defaults to false for unknown providers.
  bool requiresApiKey(String providerId) {
    return byId(providerId)?.requiresApiKey ?? false;
  }

  /// Whether the provider can be used right now.
  ///
  /// Key storage is the settings repository's concern (keys live in
  /// `flutter_secure_storage`, never in the registry), so the caller supplies
  /// [hasApiKey]. A provider that needs no key is always available; one that
  /// requires a key is available only when [hasApiKey] is true.
  bool isAvailable(String providerId, {required bool hasApiKey}) {
    final provider = byId(providerId);
    if (provider == null) return false;
    if (!provider.requiresApiKey) return true;
    return hasApiKey;
  }
}
