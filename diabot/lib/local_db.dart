import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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
  implements FsmStoreGateway, RecentEventReader, ProfileSnapshotGateway {
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
      version: 3,
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

  /// Wipes all locally stored data. Called by the build-number-triggered
  /// reset in main.dart during active testing.
  Future<void> clearAll() async {
    final db = await _open();
    await db.delete('events');
    await db.delete('fsm_audit');
    await db.delete('profile_snapshot');
  }
}
