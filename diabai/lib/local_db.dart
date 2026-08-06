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
      version: 7,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'userText',
            confidence REAL NOT NULL DEFAULT 1.0,
            derived INTEGER NOT NULL DEFAULT 0,
            validated INTEGER NOT NULL DEFAULT 1,
            event_id TEXT
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
            effect_window_end TEXT,
            confidence REAL NOT NULL,
            magnitude REAL NOT NULL,
            explanation TEXT NOT NULL,
            evidence TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            linked_event_id TEXT
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
        if (oldVersion < 5) {
          await db.execute(
            "ALTER TABLE events ADD COLUMN source TEXT NOT NULL DEFAULT 'userText'",
          );
          await db.execute(
            'ALTER TABLE events ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0',
          );
          await db.execute(
            'ALTER TABLE events ADD COLUMN derived INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE events ADD COLUMN validated INTEGER NOT NULL DEFAULT 1',
          );
          // Backfill the new `source` column for CGM readings synced before
          // this migration, whose source previously lived only inside the
          // JSON payload -- keeps deleteCgmGlucoseReadingsInWindow's dedup
          // working for already-stored data.
          await db.execute(
            "UPDATE events SET source = 'cgm' WHERE payload LIKE '%\"_source\":\"cgm\"%'",
          );
        }
        if (oldVersion < 6) {
          await db.execute('ALTER TABLE events ADD COLUMN event_id TEXT');
          await db.execute(
            'ALTER TABLE hypotheses ADD COLUMN linked_event_id TEXT',
          );
        }
        if (oldVersion < 7) {
          // Nullable: existing rows predate the causal EffectWindow model
          // (see EventHypothesis.effectWindowEnd) and fall back to
          // estimated_peak (no extension) when read — see
          // _hypothesisFromRow.
          await db.execute(
            'ALTER TABLE hypotheses ADD COLUMN effect_window_end TEXT',
          );
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
    EventSource source = EventSource.userText,
    double confidence = 1.0,
    bool derived = false,
    bool validated = true,
    String? eventId,
  }) async {
    final db = await _open();
    await db.insert('events', {
      'type': type,
      'payload': jsonEncode(fields),
      'created_at': (occurredAt ?? DateTime.now()).toIso8601String(),
      'source': source.name,
      'confidence': confidence,
      'derived': derived ? 1 : 0,
      'validated': validated ? 1 : 0,
      'event_id': eventId,
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
    };
    await logEvent(
      event.type.name,
      fields,
      occurredAt: event.createdAt,
      source: event.source,
      confidence: event.confidence,
      derived: event.derived,
      validated: event.validated,
      eventId: event.id,
    );
  }

  @override
  Future<void> storeSystemEvent(String type, Map<String, dynamic> data) =>
      logEvent(type, data, source: EventSource.system);

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

  /// Looks up one stored event by its [EventInstance.id] \u2014 used to
  /// describe an already-resolved Timeline hypothesis's linked event for
  /// review (see [HypothesisGateway.linkHypothesisToEvent]).
  Future<Map<String, dynamic>?> eventById(String eventId) async {
    final db = await _open();
    final rows = await db.query(
      'events',
      where: 'event_id = ?',
      whereArgs: [eventId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  /// Deletes one stored event by its [EventInstance.id] \u2014 used when the
  /// user chooses to redo an already-reviewed Timeline event from scratch
  /// (see main.dart's timeline review flow) instead of keeping the old row
  /// alongside the corrected one.
  Future<void> deleteEventById(String eventId) async {
    final db = await _open();
    await db.delete('events', where: 'event_id = ?', whereArgs: [eventId]);
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

  /// Returns events of [type] logged within [start]..[end] (inclusive),
  /// oldest first \u2014 unlike [recentEventsOfType], the window isn't anchored
  /// to now. Used by the drag-on-the-curve time picker
  /// (glucose_time_picker.dart) to center its mini-graph on an arbitrary
  /// moment, e.g. a confirmed hypothesis's own estimated time.
  Future<List<Map<String, dynamic>>> eventsOfTypeBetween(
    String type,
    DateTime start,
    DateTime end,
  ) async {
    final db = await _open();
    return db.query(
      'events',
      where: 'type = ? AND created_at >= ? AND created_at <= ?',
      whereArgs: [type, start.toIso8601String(), end.toIso8601String()],
      orderBy: 'id ASC',
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
          'type = ? AND created_at >= ? AND created_at <= ? AND source = ?',
      whereArgs: [
        'glucose',
        start.toIso8601String(),
        end.toIso8601String(),
        EventSource.cgm.name,
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
        'effect_window_end': hypothesis.effectWindowEnd.toIso8601String(),
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
  Future<bool> refreshPendingHypothesis(EventHypothesis hypothesis) async {
    final db = await _open();
    final updated = await db.update(
      'hypotheses',
      {
        'estimated_peak': hypothesis.estimatedPeak.toIso8601String(),
        'effect_window_end': hypothesis.effectWindowEnd.toIso8601String(),
        'confidence': hypothesis.confidence,
        'magnitude': hypothesis.magnitude,
        'explanation': hypothesis.explanation,
        'evidence': jsonEncode(hypothesis.evidence),
        'updated_at': DateTime.now().toIso8601String(),
      },
      // Never touches a row the user already resolved — see
      // [HypothesisGateway.refreshPendingHypothesis].
      where: 'id = ? AND status = ?',
      whereArgs: [hypothesis.id, HypothesisStatus.pending.name],
    );
    return updated > 0;
  }

  @override
  Future<void> prunePendingDuplicates(EventHypothesis merged) async {
    final db = await _open();
    await db.delete(
      'hypotheses',
      where: 'id != ? AND type = ? AND status = ? AND '
          'estimated_peak >= ? AND estimated_peak <= ?',
      whereArgs: [
        merged.id,
        merged.type.name,
        HypothesisStatus.pending.name,
        merged.estimatedStart.toIso8601String(),
        merged.effectWindowEnd.toIso8601String(),
      ],
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
  Future<void> linkHypothesisToEvent(String id, String eventId) async {
    final db = await _open();
    await db.update(
      'hypotheses',
      {
        'linked_event_id': eventId,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> realignHypothesisTiming(String id, DateTime estimatedStart) async {
    final db = await _open();
    final rows = await db.query('hypotheses', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final row = rows.first;
    final oldStart = DateTime.parse(row['estimated_start'] as String);
    final delta = estimatedStart.difference(oldStart);
    if (delta == Duration.zero) return;
    final effectWindowEndRaw = row['effect_window_end'] as String?;
    final newEffectWindowEnd = effectWindowEndRaw != null
        ? DateTime.parse(effectWindowEndRaw).add(delta)
        : estimatedStart;
    await db.update(
      'hypotheses',
      {
        'estimated_start': estimatedStart.toIso8601String(),
        'effect_window_end': newEffectWindowEnd.toIso8601String(),
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
    final estimatedPeak = DateTime.parse(row['estimated_peak'] as String);
    final effectWindowEndRaw = row['effect_window_end'] as String?;
    return EventHypothesis(
      id: row['id'] as String,
      type: HypothesisType.values.byName(row['type'] as String),
      status: HypothesisStatus.values.byName(row['status'] as String),
      linkedEventId: row['linked_event_id'] as String?,
      estimatedStart: DateTime.parse(row['estimated_start'] as String),
      estimatedPeak: estimatedPeak,
      // Rows stored before the EffectWindow model (see
      // EventHypothesis.effectWindowEnd) have no column value — fall back
      // to estimatedPeak (no extension) rather than crash.
      effectWindowEnd: effectWindowEndRaw != null
          ? DateTime.parse(effectWindowEndRaw)
          : estimatedPeak,
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
