import 'package:drift/drift.dart';

import '../../database/app_database.dart';

/// The last good models.dev `api.json` fetch, used as a cold-start fallback for
/// the AI provider/model catalog (stale-while-revalidate).
class CachedCatalog {
  const CachedCatalog({
    required this.rawJson,
    required this.fetchedAt,
    this.etag,
    this.lastModified,
  });

  final String rawJson;
  final DateTime fetchedAt;
  final String? etag;
  final String? lastModified;
}

/// Persists exactly one raw `api.json` blob (the catalog cold-start fallback).
abstract interface class AiCatalogCacheDatasource {
  /// Returns the cached catalog blob, or null if none has been stored yet.
  Future<CachedCatalog?> read();

  /// Overwrites the single cached blob with [rawJson] and its metadata.
  Future<void> write({
    required String rawJson,
    required DateTime fetchedAt,
    String? etag,
    String? lastModified,
  });

  /// Removes the cached blob.
  Future<void> clear();
}

class AiCatalogCacheDatasourceImpl implements AiCatalogCacheDatasource {
  const AiCatalogCacheDatasourceImpl({required AppDatabase database})
      : _database = database;

  final AppDatabase _database;

  /// Fixed primary key — the table only ever holds one row.
  static const int _singletonId = 0;

  @override
  Future<CachedCatalog?> read() async {
    final row = await (_database.select(_database.catalogCache)
          ..where((t) => t.id.equals(_singletonId)))
        .getSingleOrNull();
    if (row == null) return null;
    return CachedCatalog(
      rawJson: row.rawJson,
      fetchedAt: row.fetchedAt,
      etag: row.etag,
      lastModified: row.lastModified,
    );
  }

  @override
  Future<void> write({
    required String rawJson,
    required DateTime fetchedAt,
    String? etag,
    String? lastModified,
  }) async {
    await _database.into(_database.catalogCache).insertOnConflictUpdate(
          CatalogCacheCompanion(
            id: const Value(_singletonId),
            rawJson: Value(rawJson),
            fetchedAt: Value(fetchedAt),
            etag: Value(etag),
            lastModified: Value(lastModified),
          ),
        );
  }

  @override
  Future<void> clear() async {
    await (_database.delete(_database.catalogCache)
          ..where((t) => t.id.equals(_singletonId)))
        .go();
  }
}
