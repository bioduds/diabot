import 'dart:async';

import 'events.dart';
import 'librelinkup.dart';

/// Background follower for a linked LibreLinkUp account: polls the
/// FreeStyle Libre "graph" endpoint every
/// [FsmContract.cgmSyncIntervalSeconds] while running and stores any
/// reading newer than the last sync as an ordinary [EventType.glucose]
/// event with [EventSource.cgm]. It never asks a question, never touches
/// the live conversation stack, and never runs the Priority/Emergency
/// engines directly — see docs/fsm/cgm.mmd.
///
/// Intended lifecycle: start() once a connected account exists (app
/// foreground only, per the current scope), stop() on dispose.
class CgmSyncEngine {
  CgmSyncEngine({
    required this.credentialStore,
    required this.storeGateway,
    LibreLinkUpClient? client,
    Duration? interval,
  })  : _client = client ?? LibreLinkUpClient(),
        _interval =
            interval ?? const Duration(seconds: FsmContract.cgmSyncIntervalSeconds);

  final LibreLinkUpCredentialStore credentialStore;
  final FsmStoreGateway storeGateway;
  final LibreLinkUpClient _client;
  final Duration _interval;

  Timer? _timer;
  bool _syncing = false;

  LibreLinkUpRegion? _region;
  String? _token;
  String? _accountIdHash;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_interval, (_) => syncOnce());
    unawaited(syncOnce());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs one fetch-and-store pass. Public so tests and a manual
  /// "sync now" action can trigger it without waiting for the timer.
  Future<void> syncOnce() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final credentials = await credentialStore.load();
      if (credentials == null) return;

      var readings = await _fetchReadings(credentials, forceLogin: false);
      readings ??= await _fetchReadings(credentials, forceLogin: true);
      if (readings == null) return;

      final lastSynced = await credentialStore.lastSyncedAt;
      final newReadings = lastSynced == null
          ? readings
          : readings.where((r) => r.timestamp.isAfter(lastSynced)).toList();
      if (newReadings.isEmpty) return;

      for (final reading in newReadings) {
        final event = EventInstance(
          type: EventType.glucose,
          source: EventSource.cgm,
          createdAt: reading.timestamp,
          data: {
            'value': reading.mgdl,
            'measurementContext': 'cgm',
            if (reading.trend != null) 'trend': reading.trend,
          },
        )..transitionTo(EventStatus.stored, reason: 'cgm-auto-sync');
        await storeGateway.storeEvent(event);
      }
      await credentialStore.setLastSyncedAt(newReadings.last.timestamp);
    } catch (_) {
      // Best-effort background sync: a transient network/API failure is
      // silently retried on the next tick rather than surfaced as a chat
      // error.
    } finally {
      _syncing = false;
    }
  }

  /// Fetches the richer [LibreLinkUpSnapshot] (target range, sensor,
  /// per-reading trend/color) on demand, reusing whatever auth session
  /// [syncOnce] already established. Used by [GlucoseChartPage]'s
  /// per-minute foreground refresh; never touches `lastSyncedAt` or the
  /// event log, so it can't interfere with the background reading sync.
  Future<LibreLinkUpSnapshot?> fetchFullSnapshotOnce() async {
    final credentials = await credentialStore.load();
    if (credentials == null) return null;
    var snapshot = await _fetchSnapshot(credentials, forceLogin: false);
    snapshot ??= await _fetchSnapshot(credentials, forceLogin: true);
    return snapshot;
  }

  Future<LibreLinkUpSnapshot?> _fetchSnapshot(
    ({
      String email,
      String password,
      String regionCode,
      String patientId,
      String patientName,
    }) credentials, {
    required bool forceLogin,
  }) async {
    try {
      if (forceLogin || _token == null || _accountIdHash == null || _region == null) {
        final connected = await _client.connect(
          email: credentials.email,
          password: credentials.password,
          regionCode: credentials.regionCode,
        );
        _region = connected.region;
        _token = connected.token;
        _accountIdHash = connected.accountIdHash;
      }
      return await _client.fetchFullSnapshot(
        region: _region!,
        token: _token!,
        accountIdHash: _accountIdHash!,
        patientId: credentials.patientId,
      );
    } on LibreLinkUpException {
      _token = null;
      _accountIdHash = null;
      return null;
    }
  }

  Future<List<LibreLinkUpReading>?> _fetchReadings(
    ({
      String email,
      String password,
      String regionCode,
      String patientId,
      String patientName,
    }) credentials, {
    required bool forceLogin,
  }) async {
    try {
      if (forceLogin || _token == null || _accountIdHash == null || _region == null) {
        final connected = await _client.connect(
          email: credentials.email,
          password: credentials.password,
          regionCode: credentials.regionCode,
        );
        _region = connected.region;
        _token = connected.token;
        _accountIdHash = connected.accountIdHash;
      }
      return await _client.fetchGraphReadings(
        region: _region!,
        token: _token!,
        accountIdHash: _accountIdHash!,
        patientId: credentials.patientId,
      );
    } on LibreLinkUpException {
      _token = null;
      _accountIdHash = null;
      return null;
    }
  }
}
