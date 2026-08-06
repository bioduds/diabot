import 'package:diabai/cgm_sync_engine.dart';
import 'package:diabai/events.dart';
import 'package:diabai/librelinkup.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryGateway implements FsmStoreGateway {
  final events = <EventInstance>[];

  @override
  Future<void> recordTransition(KernelTransition transition) async {}

  @override
  Future<void> storeEvent(EventInstance event) async {
    events.add(event);
  }

  @override
  Future<void> storeSystemEvent(String type, Map<String, dynamic> data) async {}
}

class _WindowGateway implements FsmStoreGateway, CgmWindowGateway {
  final events = <EventInstance>[];
  final deletedWindows = <(DateTime, DateTime)>[];

  @override
  Future<void> recordTransition(KernelTransition transition) async {}

  @override
  Future<void> storeEvent(EventInstance event) async {
    events.add(event);
  }

  @override
  Future<void> storeSystemEvent(String type, Map<String, dynamic> data) async {}

  @override
  Future<void> deleteCgmGlucoseReadingsInWindow(
    DateTime start,
    DateTime end,
  ) async {
    deletedWindows.add((start, end));
    events.removeWhere(
      (e) =>
          e.type == EventType.glucose &&
          e.source == EventSource.cgm &&
          !e.createdAt.isBefore(start) &&
          !e.createdAt.isAfter(end),
    );
  }
}

class _FakeCredentialStore extends LibreLinkUpCredentialStore {
  _FakeCredentialStore({this.hasCredentials = true});

  final bool hasCredentials;
  DateTime? lastSynced;

  @override
  Future<
      ({
        String email,
        String password,
        String regionCode,
        String patientId,
        String patientName,
      })?> load() async {
    if (!hasCredentials) return null;
    return (
      email: 'a@b.com',
      password: 'x',
      regionCode: 'US',
      patientId: 'patient-1',
      patientName: 'Ana',
    );
  }

  @override
  Future<DateTime?> get lastSyncedAt async => lastSynced;

  @override
  Future<void> setLastSyncedAt(DateTime at) async {
    lastSynced = at;
  }
}

class _FakeClient extends LibreLinkUpClient {
  _FakeClient(this._readings);
  final List<LibreLinkUpReading> _readings;
  int connectCalls = 0;

  @override
  Future<LibreLinkUpConnectResult> connect({
    required String email,
    required String password,
    String regionCode = 'LA',
  }) async {
    connectCalls += 1;
    return LibreLinkUpConnectResult(
      region: LibreLinkUpRegion.fromCode(regionCode),
      token: 'token',
      accountIdHash: 'hash',
      patient: const LibreLinkUpPatient(
          patientId: 'patient-1', firstName: 'Ana', lastName: ''),
    );
  }

  @override
  Future<List<LibreLinkUpReading>> fetchGraphReadings({
    required LibreLinkUpRegion region,
    required String token,
    required String accountIdHash,
    required String patientId,
  }) async =>
      _readings;
}

void main() {
  test('syncOnce() is a no-op when no LibreLinkUp account is connected',
      () async {
    final gateway = _MemoryGateway();
    final engine = CgmSyncEngine(
      credentialStore: _FakeCredentialStore(hasCredentials: false),
      storeGateway: gateway,
      client: _FakeClient(const []),
    );

    await engine.syncOnce();

    expect(gateway.events, isEmpty);
  });

  test('syncOnce() stores new readings as glucose/cgm events with their '
      'true timestamp', () async {
    final gateway = _MemoryGateway();
    final t1 = DateTime(2026, 1, 1, 8);
    final t2 = DateTime(2026, 1, 1, 8, 5);
    final store = _FakeCredentialStore();
    final engine = CgmSyncEngine(
      credentialStore: store,
      storeGateway: gateway,
      client: _FakeClient([
        LibreLinkUpReading(timestamp: t1, mgdl: 100, trend: 'stable'),
        LibreLinkUpReading(timestamp: t2, mgdl: 110, trend: 'rising'),
      ]),
    );

    await engine.syncOnce();

    expect(gateway.events, hasLength(2));
    expect(gateway.events.first.type, EventType.glucose);
    expect(gateway.events.first.source, EventSource.cgm);
    expect(gateway.events.first.createdAt, t1);
    expect(gateway.events.first.data['value'], 100);
    expect(gateway.events.first.status, EventStatus.stored);
    expect(store.lastSynced, t2);
  });

  test('syncOnce() only stores readings newer than the last sync', () async {
    final gateway = _MemoryGateway();
    final t1 = DateTime(2026, 1, 1, 8);
    final t2 = DateTime(2026, 1, 1, 8, 5);
    final store = _FakeCredentialStore()..lastSynced = t1;
    final engine = CgmSyncEngine(
      credentialStore: store,
      storeGateway: gateway,
      client: _FakeClient([
        LibreLinkUpReading(timestamp: t1, mgdl: 100),
        LibreLinkUpReading(timestamp: t2, mgdl: 110),
      ]),
    );

    await engine.syncOnce();

    expect(gateway.events, hasLength(1));
    expect(gateway.events.single.createdAt, t2);
  });

  test(
      'syncOnce() ignores a future-dated last-sync cursor (self-heals a '
      'stale UTC-as-local timestamp bug) instead of starving forever',
      () async {
    final gateway = _MemoryGateway();
    final t1 = DateTime.now().add(const Duration(minutes: 5));
    final t2 = DateTime.now().add(const Duration(minutes: 10));
    final store = _FakeCredentialStore()
      ..lastSynced = DateTime.now().add(const Duration(hours: 3));
    final engine = CgmSyncEngine(
      credentialStore: store,
      storeGateway: gateway,
      client: _FakeClient([
        LibreLinkUpReading(timestamp: t1, mgdl: 100),
        LibreLinkUpReading(timestamp: t2, mgdl: 110),
      ]),
    );

    await engine.syncOnce();

    expect(gateway.events, hasLength(2));
    expect(store.lastSynced, t2);
  });

  test(
      "syncOnce() fully replaces the fetched window when storeGateway "
      "supports CgmWindowGateway, so a re-parsed reading can't coexist with "
      'a stale, differently-shifted duplicate of the same real reading',
      () async {
    final gateway = _WindowGateway();
    final t1 = DateTime(2026, 1, 1, 8);
    final t2 = DateTime(2026, 1, 1, 8, 5);
    final staleDuplicate = EventInstance(
      type: EventType.glucose,
      source: EventSource.cgm,
      createdAt: t1,
      data: {'value': 999, 'measurementContext': 'cgm'},
    )..transitionTo(EventStatus.stored, reason: 'stale');
    gateway.events.add(staleDuplicate);
    final store = _FakeCredentialStore();
    final engine = CgmSyncEngine(
      credentialStore: store,
      storeGateway: gateway,
      client: _FakeClient([
        LibreLinkUpReading(timestamp: t1, mgdl: 100, trend: 'stable'),
        LibreLinkUpReading(timestamp: t2, mgdl: 110, trend: 'rising'),
      ]),
    );

    await engine.syncOnce();

    expect(gateway.deletedWindows, [(t1, t2)]);
    expect(gateway.events, hasLength(2));
    expect(gateway.events.every((e) => e.data['value'] != 999), isTrue);
    expect(store.lastSynced, t2);
  });
}
