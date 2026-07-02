// AI subsystem schema test (review finding L17).
//
// SCOPE / LIMITATION: A *true* v7 -> v8 migration harness (build an on-disk v7
// database, run `onUpgrade`, then assert the schema matches v8) requires the
// generated per-version schema dumps that `drift_dev schema dump` /
// `drift_dev schema generate` produce under a `drift_schemas/` directory plus
// the `package:drift_dev/api/migration.dart` `SchemaVerifier` helper. Those
// schema snapshots do not exist in this repo, so a real version-stepping
// migration test is impractical here without first wiring up that codegen.
//
// Instead — exactly as the task allows — this test covers the v8 table
// definitions by opening `AppDatabase` on an in-memory `NativeDatabase`
// (which runs `onCreate` -> `createAll()`, the same `createTable` calls the
// `if (from < 8)` upgrade branch performs) and round-tripping one row through
// each of the three new tables: `catalog_cache`, `ai_config`, and
// `capability_routing`. A successful insert+read proves the `Table`
// definitions, the generated companions, and `app_database.g.dart` codegen are
// mutually valid and that the tables are created by the migration strategy.
//
// (This is a drift schema/round-trip test, so the repo's mockito
// `@GenerateMocks` convention does not apply — there is no collaborator to
// mock; the real in-memory database is the unit under test.)

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    // In-memory executor — no files, no platform channels, fresh per test.
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('AI subsystem schema (v8)', () {
    test('schemaVersion is at least 8', () {
      // Not pinned to exactly 8 — later migrations (e.g. v9's
      // ScheduledReminders table) legitimately bump this further; this test
      // only asserts the v8 AI tables exist and round-trip correctly below.
      expect(db.schemaVersion, greaterThanOrEqualTo(8));
    });

    test('the three new AI tables exist after createAll/onUpgrade', () async {
      // Forces the lazy connection to open and run the migration strategy.
      final rows = await db.customSelect(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' "
        "AND name IN ('catalog_cache', 'ai_config', 'capability_routing')",
      ).get();

      final names = rows.map((r) => r.data['name'] as String).toSet();
      expect(
        names,
        containsAll(<String>{'catalog_cache', 'ai_config', 'capability_routing'}),
      );
    });

    test('catalog_cache round-trips a single-row blob', () async {
      final fetchedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      await db.into(db.catalogCache).insert(
            CatalogCacheCompanion.insert(
              id: const Value(0), // single-row contract: always id 0
              rawJson: '{"providers":[]}',
              fetchedAt: fetchedAt,
              etag: const Value('"abc123"'),
              lastModified: const Value('Wed, 21 Oct 2026 07:28:00 GMT'),
            ),
          );

      final row = await db.select(db.catalogCache).getSingle();
      expect(row.id, 0); // single-row contract
      expect(row.rawJson, '{"providers":[]}');
      expect(row.fetchedAt, fetchedAt);
      expect(row.etag, '"abc123"');
      expect(row.lastModified, 'Wed, 21 Oct 2026 07:28:00 GMT');
    });

    test('ai_config round-trips a configured provider row', () async {
      await db.into(db.aiConfig).insert(
            AiConfigCompanion.insert(
              id: 'cfg-1',
              providerId: 'anthropic',
              source: 'catalog',
              wireProtocol: 'anthropic',
              kind: 'cloud',
              displayName: const Value('Anthropic'),
              apiBaseUrl: const Value.absent(), // nullable -> stays null
            ),
          );

      final row = await db.select(db.aiConfig).getSingle();
      expect(row.id, 'cfg-1');
      expect(row.providerId, 'anthropic');
      expect(row.source, 'catalog');
      expect(row.wireProtocol, 'anthropic');
      expect(row.kind, 'cloud');
      expect(row.displayName, 'Anthropic');
      expect(row.apiBaseUrl, isNull);
    });

    test('capability_routing round-trips a capability -> model mapping',
        () async {
      await db.into(db.capabilityRouting).insert(
            CapabilityRoutingCompanion.insert(
              capability: 'compose',
              providerId: 'anthropic',
              modelId: 'claude-sonnet-4',
            ),
          );

      final row = await db.select(db.capabilityRouting).getSingle();
      expect(row.capability, 'compose');
      expect(row.providerId, 'anthropic');
      expect(row.modelId, 'claude-sonnet-4');
    });

    test('capability_routing capability is the primary key (upsert replaces)',
        () async {
      Future<void> route(String providerId, String modelId) =>
          db.into(db.capabilityRouting).insertOnConflictUpdate(
                CapabilityRoutingCompanion.insert(
                  capability: 'summarize',
                  providerId: providerId,
                  modelId: modelId,
                ),
              );

      await route('openai', 'gpt-4o-mini');
      await route('local', 'llama-3.1-8b');

      final rows = await db.select(db.capabilityRouting).get();
      expect(rows, hasLength(1));
      expect(rows.single.providerId, 'local');
      expect(rows.single.modelId, 'llama-3.1-8b');
    });
  });
}
