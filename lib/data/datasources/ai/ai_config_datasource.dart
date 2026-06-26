import 'package:drift/drift.dart';

import '../../../domain/entities/ai/ai_provider.dart';
import '../../database/app_database.dart';

/// A durable AI provider configuration row (catalog pick or BYO endpoint).
/// API keys are NOT held here — they live in flutter_secure_storage by
/// providerId.
class AiConfigEntry {
  const AiConfigEntry({
    required this.id,
    required this.providerId,
    required this.source,
    required this.wireProtocol,
    required this.kind,
    this.displayName,
    this.apiBaseUrl,
  });

  final String id;
  final String providerId;

  /// `catalog | user`.
  final String source;

  /// `openai | anthropic | google | ollama | azure`.
  final String wireProtocol;

  /// `cloud | local | selfHosted`.
  final String kind;

  final String? displayName;
  final String? apiBaseUrl;
}

/// Maps an AI capability (`compose | summarize | triage | search`) to a
/// `(providerId, modelId)` backend.
class CapabilityRoute {
  const CapabilityRoute({
    required this.capability,
    required this.providerId,
    required this.modelId,
  });

  final String capability;
  final String providerId;
  final String modelId;
}

/// CRUD over the durable AI config (`ai_config`) and per-capability routing
/// (`capability_routing`) drift tables.
abstract interface class AiConfigDatasource {
  Future<List<AiConfigEntry>> getConfigs();
  Future<AiConfigEntry?> getConfig(String id);
  Future<void> upsertConfig(AiConfigEntry entry);
  Future<void> deleteConfig(String id);

  /// Every durable configured provider (both BYO and catalog picks). The
  /// registry overlays these onto the catalog so user-supplied endpoints (e.g.
  /// an Azure resource URL on a catalog provider) take effect.
  Future<List<AiProvider>> getConfiguredProviders();

  Future<List<CapabilityRoute>> getRoutes();
  Future<CapabilityRoute?> getRoute(String capability);
  Future<void> upsertRoute(CapabilityRoute route);
  Future<void> deleteRoute(String capability);
}

class AiConfigDatasourceImpl implements AiConfigDatasource {
  const AiConfigDatasourceImpl({required AppDatabase database})
      : _database = database;

  final AppDatabase _database;

  @override
  Future<List<AiConfigEntry>> getConfigs() async {
    final rows = await _database.select(_database.aiConfig).get();
    return rows.map(_toConfigEntry).toList();
  }

  @override
  Future<AiConfigEntry?> getConfig(String id) async {
    final row = await (_database.select(_database.aiConfig)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toConfigEntry(row);
  }

  @override
  Future<void> upsertConfig(AiConfigEntry entry) async {
    await _database.into(_database.aiConfig).insertOnConflictUpdate(
          AiConfigCompanion(
            id: Value(entry.id),
            providerId: Value(entry.providerId),
            source: Value(entry.source),
            displayName: Value(entry.displayName),
            apiBaseUrl: Value(entry.apiBaseUrl),
            wireProtocol: Value(entry.wireProtocol),
            kind: Value(entry.kind),
          ),
        );
  }

  @override
  Future<void> deleteConfig(String id) async {
    await (_database.delete(_database.aiConfig)..where((t) => t.id.equals(id)))
        .go();
  }

  @override
  Future<List<CapabilityRoute>> getRoutes() async {
    final rows = await _database.select(_database.capabilityRouting).get();
    return rows.map(_toRoute).toList();
  }

  @override
  Future<CapabilityRoute?> getRoute(String capability) async {
    final row = await (_database.select(_database.capabilityRouting)
          ..where((t) => t.capability.equals(capability)))
        .getSingleOrNull();
    return row == null ? null : _toRoute(row);
  }

  @override
  Future<void> upsertRoute(CapabilityRoute route) async {
    await _database.into(_database.capabilityRouting).insertOnConflictUpdate(
          CapabilityRoutingCompanion(
            capability: Value(route.capability),
            providerId: Value(route.providerId),
            modelId: Value(route.modelId),
          ),
        );
  }

  @override
  Future<void> deleteRoute(String capability) async {
    await (_database.delete(_database.capabilityRouting)
          ..where((t) => t.capability.equals(capability)))
        .go();
  }

  @override
  Future<List<AiProvider>> getConfiguredProviders() async {
    final configs = await getConfigs();
    return configs.map(_toProvider).toList();
  }

  AiProvider _toProvider(AiConfigEntry e) {
    final kind = _parseKind(e.kind);
    return AiProvider(
      id: e.providerId,
      name: e.displayName ?? e.providerId,
      npm: '',
      doc: '',
      // Reconstruct env so `requiresApiKey` reflects the provider kind: local
      // providers need no key, every other kind expects one (mirrors
      // AiSettingsRepositoryImpl._toProvider).
      env: kind == AiProviderKind.local
          ? const <String>[]
          : const <String>['API_KEY'],
      apiBaseUrl: e.apiBaseUrl,
      kind: kind,
      wireProtocol: _parseWireProtocol(e.wireProtocol),
      // Honor the stored source column instead of force-tagging every row as
      // user; catalog picks must stay tagged catalog.
      source: _parseSource(e.source),
    );
  }

  static AiProviderSource _parseSource(String source) =>
      AiProviderSource.values.firstWhere(
        (s) => s.name == source,
        orElse: () => AiProviderSource.user,
      );

  static AiProviderKind _parseKind(String kind) {
    switch (kind) {
      case 'local':
        return AiProviderKind.local;
      case 'selfHosted':
        return AiProviderKind.selfHosted;
      default:
        return AiProviderKind.cloud;
    }
  }

  static AiWireProtocol _parseWireProtocol(String wire) {
    switch (wire) {
      case 'anthropic':
        return AiWireProtocol.anthropic;
      case 'google':
        return AiWireProtocol.google;
      case 'ollama':
        return AiWireProtocol.ollama;
      case 'azure':
        return AiWireProtocol.azure;
      default:
        return AiWireProtocol.openai;
    }
  }

  AiConfigEntry _toConfigEntry(AiConfigData row) => AiConfigEntry(
        id: row.id,
        providerId: row.providerId,
        source: row.source,
        displayName: row.displayName,
        apiBaseUrl: row.apiBaseUrl,
        wireProtocol: row.wireProtocol,
        kind: row.kind,
      );

  CapabilityRoute _toRoute(CapabilityRoutingData row) => CapabilityRoute(
        capability: row.capability,
        providerId: row.providerId,
        modelId: row.modelId,
      );
}
