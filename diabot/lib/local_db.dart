import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'cgm/past_event_interpreter.dart';
import 'cgm_sync_engine.dart' show CgmWindowGateway;
import 'events.dart';

/// Local-only SQLite event log: every piece of health data DiabAI collects
/// (meals, exercise, glucose readings, insulin doses, symptom reports) is
/// persisted here as a typed, timestamped event, independent of the chat
/// UI. This is the foundation of the "complete local data control" system
/// — future screens (history, charts, CSV export) can all read from this
/// same table.
///
/// Nothing here ever leaves the device; there is no network sync.
class LocalDatabase
  implements
      FsmStoreGateway,
      RecentEventReader,
      ProfileSnapshotGateway,
      CgmWindowGateway,
      HypothesisGateway {
  LocalDatabase._();
  static final LocalDatabase instance = LocalDatabase._();

  Database? _db;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'diabai.db');
    final db = await openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE fsm_audit (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            from_status TEXT NOT NULL,
            to_status TEXT NOT NULL,
            global_state TEXT NOT NULL,
            reason TEXT,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE profile_snapshot (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            payload TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE hypotheses (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            status TEXT NOT NULL,
            estimated_start TEXT NOT NULL,
            estimated_peak TEXT NOT NULL,
            confidence REAL NOT NULL,
            magnitude REAL NOT NULL,
            explanation TEXT NOT NULL,
            evidence TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE fsm_audit (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              event_id TEXT NOT NULL,
              event_type TEXT NOT NULL,
              from_status TEXT NOT NULL,
              to_status TEXT NOT NULL,
              global_state TEXT NOT NULL,
              reason TEXT,
              created_at TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE profile_snapshot (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              payload TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE hypotheses (
              id TEXT PRIMARY KEY,
              type TEXT NOT NULL,
              status TEXT NOT NULL,
              estimated_start TEXT NOT NULL,
              estimated_peak TEXT NOT NULL,
              confidence REAL NOT NULL,
              magnitude REAL NOT NULL,
              explanation TEXT NOT NULL,
              evidence TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        }
      },
    );
    _db = db;
    return db;
  }

  /// Persists one orchestrated event (e.g. a logged meal or glucose
  /// reading). [type] matches the FSM's event type name (e.g. "meal",
  /// "exercise", "glucose", "insulin", "symptoms", "emergency"). Defaults
  /// [occurredAt] to now for interactively-collected events; CGM auto-sync
  /// passes the sensor's own reading time so history/charts stay accurate.
  Future<void> logEvent(
    String type,
    Map<String, dynamic> fields, {
    DateTime? occurredAt,
  }) async {
    final db = await _open();
    await db.insert('events', {
      'type': type,
      'payload': jsonEncode(fields),
      'created_at': (occurredAt ?? DateTime.now()).toIso8601String(),
    });
  }

  @override
  Future<void> storeEvent(EventInstance event) async {
    final fields = <String, dynamic>{
      for (final entry in event.data.entries)
        if (entry.value != null &&
            entry.key != 'raw_text' &&
            !entry.key.startsWith('_'))
          entry.key: entry.value,
      '_event_id': event.id,
      '_source': event.source.name,
    };
    await logEvent(event.type.name, fields, occurredAt: event.createdAt);
  }

  @override
  Future<void> storeSystemEvent(String type, Map<String, dynamic> data) =>
      logEvent(type, data);

  @override
  Future<void> recordTransition(KernelTransition transition) async {
    final db = await _open();
    await db.insert('fsm_audit', {
      'event_id': transition.eventId,
      'event_type': transition.eventType.name,
      'from_status': transition.from.name,
      'to_status': transition.to.name,
      'global_state': transition.globalState.name,
      'reason': transition.reason,
      'created_at': transition.at.toIso8601String(),
    });
  }

  /// Returns the most recent events, newest first (for a future history
  /// screen).
  Future<List<Map<String, dynamic>>> recentEvents({int limit = 100}) async {
    final db = await _open();
    return db.query('events', orderBy: 'id DESC', limit: limit);
  }

  /// Returns events of [type] logged within [within] of now, newest first.
  /// Used by the Emergency Engine to weigh recent insulin/exercise history.
  @override
  Future<List<Map<String, dynamic>>> recentEventsOfType(
    String type,
    Duration within,
  ) async {
    final db = await _open();
    final cutoff = DateTime.now().subtract(within).toIso8601String();
    return db.query(
      'events',
      where: 'type = ? AND created_at >= ?',
      whereArgs: [type, cutoff],
      orderBy: 'id DESC',
    );
  }

  /// Deletes stored `glucose` events timestamped further into the future
  /// than [tolerance] \u2014 never real physiology, only possible from a
  /// clock-skew or timezone-parsing bug (a past bug stored LibreLinkUp's
  /// UTC timestamp as if it were already local, landing hours ahead of
  /// now). Scoped to `glucose` only; other event types are untouched.
  Future<void> deleteFutureGlucoseReadings({
    Duration tolerance = const Duration(minutes: 2),
  }) async {
    final db = await _open();
    final cutoff = DateTime.now().add(tolerance).toIso8601String();
    await db.delete(
      'events',
      where: 'type = ? AND created_at > ?',
      whereArgs: ['glucose', cutoff],
    );
  }

  /// Deletes previously-synced CGM glucose events in [start]..[end] so
  /// [CgmSyncEngine] can fully replace that window with a fresh fetch —
  /// otherwise a corrected re-parse of the same period could sit right
  /// alongside a stale, differently-shifted duplicate of the same real
  /// reading (e.g. from the old UTC-as-local timestamp bug), zig-zagging
  /// the chart between the two versions of the same history.
  @override
  Future<void> deleteCgmGlucoseReadingsInWindow(
    DateTime start,
    DateTime end,
  ) async {
    final db = await _open();
    await db.delete(
      'events',
      where:
          'type = ? AND created_at >= ? AND created_at <= ? AND payload LIKE ?',
      whereArgs: [
        'glucose',
        start.toIso8601String(),
        end.toIso8601String(),
        '%"_source":"cgm"%',
      ],
    );
  }

  Future<List<Map<String, dynamic>>> recentTransitions({int limit = 200}) async {
    final db = await _open();
    return db.query('fsm_audit', orderBy: 'id DESC', limit: limit);
  }

  @override
  Future<Map<String, dynamic>?> loadProfileSnapshot() async {
    final db = await _open();
    final rows = await db.query('profile_snapshot', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    try {
      return jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveProfileSnapshot(Map<String, dynamic> snapshot) async {
    final db = await _open();
    await db.insert(
      'profile_snapshot',
      {
        'id': 1,
        'payload': jsonEncode(snapshot),
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> upsertHypothesisIfAbsent(EventHypothesis hypothesis) async {
    final db = await _open();
    final now = DateTime.now().toIso8601String();
    await db.insert(
      'hypotheses',
      {
        'id': hypothesis.id,
        'type': hypothesis.type.name,
        'status': hypothesis.status.name,
        'estimated_start': hypothesis.estimatedStart.toIso8601String(),
        'estimated_peak': hypothesis.estimatedPeak.toIso8601String(),
        'confidence': hypothesis.confidence,
        'magnitude': hypothesis.magnitude,
        'explanation': hypothesis.explanation,
        'evidence': jsonEncode(hypothesis.evidence),
        'created_at': now,
        'updated_at': now,
      },
      // Never overwrites a row the user already resolved — see
      // [HypothesisGateway.upsertHypothesisIfAbsent].
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<void> updateHypothesisStatus(
    String id, {
    required HypothesisStatus status,
    HypothesisType? type,
  }) async {
    final db = await _open();
    await db.update(
      'hypotheses',
      {
        'status': status.name,
        if (type != null) 'type': type.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<List<EventHypothesis>> hypothesesInWindow(
    DateTime start,
    DateTime end,
  ) async {
    final db = await _open();
    final rows = await db.query(
      'hypotheses',
      where: 'estimated_peak >= ? AND estimated_peak <= ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()],
      orderBy: 'estimated_peak ASC',
    );
    return rows.map(_hypothesisFromRow).toList();
  }

  EventHypothesis _hypothesisFromRow(Map<String, dynamic> row) {
    Map<String, dynamic> evidence;
    try {
      evidence = jsonDecode(row['evidence'] as String) as Map<String, dynamic>;
    } catch (_) {
      evidence = const {};
    }
    return EventHypothesis(
      id: row['id'] as String,
      type: HypothesisType.values.byName(row['type'] as String),
      status: HypothesisStatus.values.byName(row['status'] as String),
      estimatedStart: DateTime.parse(row['estimated_start'] as String),
      estimatedPeak: DateTime.parse(row['estimated_peak'] as String),
      confidence: (row['confidence'] as num).toDouble(),
      magnitude: (row['magnitude'] as num).toDouble(),
      explanation: row['explanation'] as String,
      evidence: evidence,
    );
  }

  /// Wipes all locally stored data. Called by the build-number-triggered
  /// reset in main.dart during active testing.
  Future<void> clearAll() async {
    final db = await _open();
    await db.delete('events');
    await db.delete('fsm_audit');
    await db.delete('profile_snapshot');
    await db.delete('hypotheses');
  }
}
