import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

/// Direct, on-device port of the LibreLinkUp REST flow already used by
/// GlycoGuide's Python `app/librelinkup_sync.py` (see AGENTS.md: the two
/// apps stay independent, but the same publicly documented LibreLinkUp API
/// is reimplemented here in Dart). Covers login, listing linked patients,
/// and fetching the last ~12h of glucose readings ("graph" endpoint).
class LibreLinkUpRegion {
  const LibreLinkUpRegion._(this.code, this.baseUrl);

  final String code;
  final String baseUrl;

  static const values = <LibreLinkUpRegion>[
    LibreLinkUpRegion._('AE', 'https://api-ae.libreview.io'),
    LibreLinkUpRegion._('AP', 'https://api-ap.libreview.io'),
    LibreLinkUpRegion._('AU', 'https://api-au.libreview.io'),
    LibreLinkUpRegion._('CA', 'https://api-ca.libreview.io'),
    LibreLinkUpRegion._('DE', 'https://api-de.libreview.io'),
    LibreLinkUpRegion._('EU', 'https://api-eu.libreview.io'),
    LibreLinkUpRegion._('EU2', 'https://api-eu2.libreview.io'),
    LibreLinkUpRegion._('FR', 'https://api-fr.libreview.io'),
    LibreLinkUpRegion._('JP', 'https://api-jp.libreview.io'),
    LibreLinkUpRegion._('LA', 'https://api-la.libreview.io'),
    LibreLinkUpRegion._('RU', 'https://api.libreview.ru'),
    LibreLinkUpRegion._('US', 'https://api.libreview.io'),
  ];

  static LibreLinkUpRegion fromCode(String code) {
    final upper = code.trim().toUpperCase();
    for (final region in values) {
      if (region.code == upper) return region;
    }
    return values.firstWhere((r) => r.code == 'LA');
  }
}

class LibreLinkUpPatient {
  const LibreLinkUpPatient({
    required this.patientId,
    required this.firstName,
    required this.lastName,
  });

  final String patientId;
  final String firstName;
  final String lastName;

  String get fullName => [firstName, lastName]
      .where((part) => part.trim().isNotEmpty)
      .join(' ')
      .trim();
}

/// One glucose measurement returned by the LibreLinkUp "graph" endpoint,
/// normalized to mg/dL (LibreLinkUp always reports `ValueInMgPerDl`).
class LibreLinkUpReading {
  const LibreLinkUpReading({
    required this.timestamp,
    required this.mgdl,
    this.trend,
  });

  final DateTime timestamp;
  final double mgdl;

  /// One of: falling quickly, falling, stable, rising, rising quickly.
  final String? trend;
}

/// Rising/falling direction, normalized from LibreLinkUp's `TrendArrow` int
/// so callers never juggle magic numbers.
enum CgmTrend { fallingQuickly, falling, stable, rising, risingQuickly }

const Map<int, CgmTrend> _trendByArrow = {
  1: CgmTrend.fallingQuickly,
  2: CgmTrend.falling,
  3: CgmTrend.stable,
  4: CgmTrend.rising,
  5: CgmTrend.risingQuickly,
};

/// One glucose measurement, normalized from whichever LibreLinkUp field it
/// came from (`graphData[]` or `connection.glucoseMeasurement`) and
/// including everything the API reports about that single reading beyond
/// the raw mg/dL value.
class CgmReading {
  const CgmReading({
    required this.timestamp,
    required this.mgdl,
    this.trend,
    this.trendMessage,
    this.isHigh = false,
    this.isLow = false,
    this.measurementColor,
  });

  final DateTime timestamp;
  final double mgdl;
  final CgmTrend? trend;

  /// Abbott's own free-text trend wording (e.g. "Rising"), when present.
  final String? trendMessage;
  final bool isHigh;
  final bool isLow;

  /// Abbott's own green/yellow/red classification for this reading, when
  /// the API includes it (only seen on `connection.glucoseMeasurement`).
  final String? measurementColor;
}

/// Metadata about the sensor currently worn by the patient. Every field is
/// nullable/best-effort: LibreLinkUp is an unofficial, undocumented API, so
/// this parses defensively and simply omits what it can't find rather than
/// guessing.
class SensorInfo {
  const SensorInfo({this.serialNumber, this.activationDate, this.productTypeCode});

  final String? serialNumber;
  final DateTime? activationDate;
  final int? productTypeCode;

  /// Days left in the standard 14-day Libre wear cycle, or null if the
  /// activation date is unknown.
  int? daysRemaining({int sensorLifespanDays = 14, DateTime? asOf}) {
    final activation = activationDate;
    if (activation == null) return null;
    final elapsed = (asOf ?? DateTime.now()).difference(activation).inDays;
    return (sensorLifespanDays - elapsed).clamp(0, sensorLifespanDays);
  }
}

/// The patient's own configured thresholds in LibreView — set by the
/// patient or their clinician, distinct from any default the app might
/// otherwise hardcode.
class PatientTargets {
  const PatientTargets({
    this.targetLow,
    this.targetHigh,
    this.alarmLow,
    this.alarmHigh,
    this.unitCode,
  });

  final double? targetLow;
  final double? targetHigh;
  final double? alarmLow;
  final double? alarmHigh;

  /// LibreLinkUp's `uom`: 1 = mg/dL, 2 = mmol/L.
  final int? unitCode;

  bool get isMgDl => unitCode == null || unitCode == 1;
}

/// Everything [LibreLinkUpClient.fetchFullSnapshot] could gather in one
/// call: the reading history, the current reading, and whatever
/// sensor/target metadata the API exposed for this patient.
class LibreLinkUpSnapshot {
  const LibreLinkUpSnapshot({
    required this.readings,
    this.current,
    this.sensor,
    this.targets,
  });

  final List<CgmReading> readings;
  final CgmReading? current;
  final SensorInfo? sensor;
  final PatientTargets? targets;
}

class LibreLinkUpException implements Exception {
  LibreLinkUpException(this.message);
  final String message;

  @override
  String toString() => message;
}

class LibreLinkUpConnectResult {
  const LibreLinkUpConnectResult({
    required this.region,
    required this.token,
    required this.accountIdHash,
    required this.patient,
  });

  final LibreLinkUpRegion region;
  final String token;
  final String accountIdHash;
  final LibreLinkUpPatient patient;
}

const Map<int, String> _trendLabels = {
  1: 'falling quickly',
  2: 'falling',
  3: 'stable',
  4: 'rising',
  5: 'rising quickly',
};

/// Thin REST client for the LibreLinkUp API used by the FreeStyle Libre
/// Android/iOS "LibreLinkUp" follower app. See docs/fsm/cgm.mmd.
class LibreLinkUpClient {
  LibreLinkUpClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const Map<String, String> _baseHeaders = {
    'content-type': 'application/json',
    'product': 'llu.android',
    'version': '4.16.0',
  };

  Map<String, String> _headers({String? token, String? accountIdHash}) {
    final headers = {..._baseHeaders};
    if (token != null) headers['authorization'] = 'Bearer $token';
    if (accountIdHash != null) headers['account-id'] = accountIdHash;
    return headers;
  }

  /// Logs in, follows a regional redirect if needed, then fetches the
  /// first linked patient. Throws [LibreLinkUpException] with a
  /// user-presentable message on any failure.
  Future<LibreLinkUpConnectResult> connect({
    required String email,
    required String password,
    String regionCode = 'LA',
  }) async {
    var region = LibreLinkUpRegion.fromCode(regionCode);
    var login = await _login(region, email, password);
    if (login.redirectRegion != null) {
      region = login.redirectRegion!;
      login = await _login(region, email, password);
    }

    final token = login.token;
    final accountIdHash = login.accountIdHash;
    if (token == null || accountIdHash == null) {
      throw LibreLinkUpException(
          'Falha ao autenticar no LibreLinkUp (redirecionamento inesperado).');
    }

    final patients = await _fetchPatients(
      region,
      token: token,
      accountIdHash: accountIdHash,
    );
    if (patients.isEmpty) {
      throw LibreLinkUpException(
        'Nenhum paciente vinculado a essa conta LibreLinkUp. '
        'Compartilhe os dados com esse login no aplicativo LibreLinkUp primeiro.',
      );
    }

    return LibreLinkUpConnectResult(
      region: region,
      token: token,
      accountIdHash: accountIdHash,
      patient: patients.first,
    );
  }

  /// Fetches approximately the last 12h of glucose readings for
  /// [patientId], newest last.
  Future<List<LibreLinkUpReading>> fetchGraphReadings({
    required LibreLinkUpRegion region,
    required String token,
    required String accountIdHash,
    required String patientId,
  }) async {
    final uri = Uri.parse('${region.baseUrl}/llu/connections/$patientId/graph');
    final response = await _http.get(
      uri,
      headers: _headers(token: token, accountIdHash: accountIdHash),
    );
    if (response.statusCode != 200) {
      throw LibreLinkUpException(
          'Falha ao buscar dados do LibreLinkUp (HTTP ${response.statusCode}).');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>?;
    final graphData = data?['graphData'] as List<dynamic>? ?? const [];
    final readings = <LibreLinkUpReading>[];
    for (final raw in graphData) {
      final reading = _parseMeasurement(raw as Map<String, dynamic>);
      if (reading != null) readings.add(reading);
    }
    // `graphData` can lag behind by one sensor cycle; `connection.glucoseMeasurement`
    // is LibreLinkUp's own authoritative "latest reading" field, so it always wins.
    final connection = data?['connection'] as Map<String, dynamic>?;
    final latestRaw = connection?['glucoseMeasurement'] as Map<String, dynamic>? ??
        connection?['glucoseItem'] as Map<String, dynamic>?;
    if (latestRaw != null) {
      final latest = _parseMeasurement(latestRaw);
      if (latest != null && !readings.any((r) => r.timestamp == latest.timestamp)) {
        readings.add(latest);
      }
    }
    readings.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return readings;
  }

  /// Fetches the same `/graph` payload as [fetchGraphReadings] but keeps
  /// the target range, sensor, and per-reading trend/color metadata that
  /// method discards. Every field is best-effort: this is an unofficial
  /// API, so missing/renamed fields degrade to `null` instead of throwing.
  Future<LibreLinkUpSnapshot> fetchFullSnapshot({
    required LibreLinkUpRegion region,
    required String token,
    required String accountIdHash,
    required String patientId,
  }) async {
    final uri = Uri.parse('${region.baseUrl}/llu/connections/$patientId/graph');
    final response = await _http.get(
      uri,
      headers: _headers(token: token, accountIdHash: accountIdHash),
    );
    if (response.statusCode != 200) {
      throw LibreLinkUpException(
          'Falha ao buscar dados do LibreLinkUp (HTTP ${response.statusCode}).');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>?;
    final graphData = data?['graphData'] as List<dynamic>? ?? const [];
    final readings = <CgmReading>[];
    for (final raw in graphData) {
      final reading = _parseCgmReading(raw as Map<String, dynamic>);
      if (reading != null) readings.add(reading);
    }

    final connection = data?['connection'] as Map<String, dynamic>?;
    final latestRaw = connection?['glucoseMeasurement'] as Map<String, dynamic>? ??
        connection?['glucoseItem'] as Map<String, dynamic>?;
    final current = latestRaw != null ? _parseCgmReading(latestRaw) : null;
    if (current != null && !readings.any((r) => r.timestamp == current.timestamp)) {
      readings.add(current);
    }
    readings.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return LibreLinkUpSnapshot(
      readings: readings,
      current: current ?? (readings.isNotEmpty ? readings.last : null),
      sensor: _parseSensorInfo(connection, data),
      targets: _parseTargets(connection),
    );
  }

  // LibreLinkUp always returns FactoryTimestamp in UTC and Timestamp in the
  // reader/phone's local time (same convention GlycoGuide's Python side
  // relies on in librelinkup_sync.py). Treating FactoryTimestamp as local,
  // as this port previously did, shifts every reading by the device's UTC
  // offset — e.g. showing a reading as being hours in the future in Brazil
  // (UTC-3), which then anchors the chart window past the real "now" and
  // hides all the actual data to the left of that fake future edge.
  static const _libreDateFormat = 'M/d/yyyy h:mm:ss a';

  DateTime? _parseLibreTimestamp(Map<String, dynamic> json) {
    final factoryRaw = json['FactoryTimestamp'] as String?;
    if (factoryRaw != null) {
      try {
        return DateFormat(_libreDateFormat).parseUtc(factoryRaw).toLocal();
      } catch (_) {
        return null;
      }
    }
    final localRaw = json['Timestamp'] as String?;
    if (localRaw != null) {
      try {
        return DateFormat(_libreDateFormat).parse(localRaw);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  LibreLinkUpReading? _parseMeasurement(Map<String, dynamic> json) {
    final timestamp = _parseLibreTimestamp(json);
    if (timestamp == null) return null;
    final mgdl = (json['ValueInMgPerDl'] as num?)?.toDouble() ??
        (json['Value'] as num?)?.toDouble();
    if (mgdl == null) return null;
    final trendArrow = json['TrendArrow'] as int?;
    return LibreLinkUpReading(
      timestamp: timestamp,
      mgdl: mgdl,
      trend: trendArrow != null ? _trendLabels[trendArrow] : null,
    );
  }

  CgmReading? _parseCgmReading(Map<String, dynamic> json) {
    final timestamp = _parseLibreTimestamp(json);
    if (timestamp == null) return null;
    final mgdl = (json['ValueInMgPerDl'] as num?)?.toDouble() ??
        (json['Value'] as num?)?.toDouble();
    if (mgdl == null) return null;
    final trendArrow = json['TrendArrow'] as int?;
    return CgmReading(
      timestamp: timestamp,
      mgdl: mgdl,
      trend: trendArrow != null ? _trendByArrow[trendArrow] : null,
      trendMessage: json['TrendMessage'] as String?,
      isHigh: json['isHigh'] as bool? ?? false,
      isLow: json['isLow'] as bool? ?? false,
      measurementColor: json['MeasurementColor'] as String?,
    );
  }

  SensorInfo? _parseSensorInfo(
    Map<String, dynamic>? connection,
    Map<String, dynamic>? data,
  ) {
    Map<String, dynamic>? sensor = connection?['sensor'] as Map<String, dynamic>?;
    if (sensor == null) {
      final activeSensors = data?['activeSensors'] as List<dynamic>?;
      final first = activeSensors != null && activeSensors.isNotEmpty
          ? activeSensors.first as Map<String, dynamic>?
          : null;
      sensor = first?['sensor'] as Map<String, dynamic>?;
    }
    if (sensor == null) return null;
    final serial = sensor['sn'] as String?;
    final activationEpoch = sensor['a'] as int?;
    return SensorInfo(
      serialNumber: serial,
      activationDate: activationEpoch != null
          ? DateTime.fromMillisecondsSinceEpoch(activationEpoch * 1000)
          : null,
      productTypeCode: sensor['pt'] as int?,
    );
  }

  PatientTargets? _parseTargets(Map<String, dynamic>? connection) {
    if (connection == null) return null;
    final targetLow = (connection['targetLow'] as num?)?.toDouble();
    final targetHigh = (connection['targetHigh'] as num?)?.toDouble();
    final alarmRules = connection['alarmRules'] as Map<String, dynamic>?;
    final alarmLow = (alarmRules?['l'] as num?)?.toDouble();
    final alarmHigh = (alarmRules?['h'] as num?)?.toDouble();
    final unitCode = connection['uom'] as int?;
    if (targetLow == null &&
        targetHigh == null &&
        alarmLow == null &&
        alarmHigh == null &&
        unitCode == null) {
      return null;
    }
    return PatientTargets(
      targetLow: targetLow,
      targetHigh: targetHigh,
      alarmLow: alarmLow,
      alarmHigh: alarmHigh,
      unitCode: unitCode,
    );
  }

  Future<_LoginResult> _login(
    LibreLinkUpRegion region,
    String email,
    String password,
  ) async {
    final uri = Uri.parse('${region.baseUrl}/llu/auth/login');
    late http.Response response;
    try {
      response = await _http.post(
        uri,
        headers: _headers(),
        body: jsonEncode({'email': email, 'password': password}),
      );
    } on Exception {
      throw LibreLinkUpException(
          'Não foi possível conectar ao LibreLinkUp. Verifique sua internet.');
    }

    if (response.statusCode == 429) {
      throw LibreLinkUpException(
          'Muitas tentativas no LibreLinkUp. Tente novamente em alguns minutos.');
    }
    if (response.statusCode != 200) {
      throw LibreLinkUpException(
          'E-mail ou senha do LibreLinkUp inválidos.');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>? ?? const {};

    if (data['redirect'] == true) {
      final redirectRegion =
          LibreLinkUpRegion.fromCode(data['region'] as String? ?? region.code);
      return _LoginResult(redirectRegion: redirectRegion);
    }

    final stepType = (data['step'] as Map<String, dynamic>?)?['type'];
    switch (stepType) {
      case 'tou':
        throw LibreLinkUpException(
            'Aceite os termos de uso do LibreLinkUp no aplicativo móvel e tente novamente.');
      case 'pp':
        throw LibreLinkUpException(
            'Aceite a política de privacidade do LibreLinkUp no aplicativo móvel e tente novamente.');
      case 'verifyEmail':
        throw LibreLinkUpException(
            'Verifique seu e-mail do LibreLinkUp e tente novamente.');
    }

    final authTicket = data['authTicket'] as Map<String, dynamic>?;
    final token = authTicket?['token'] as String?;
    final userId = (data['user'] as Map<String, dynamic>?)?['id'] as String?;
    if (token == null || token.isEmpty || userId == null || userId.isEmpty) {
      throw LibreLinkUpException('E-mail ou senha do LibreLinkUp inválidos.');
    }
    final accountIdHash = sha256.convert(utf8.encode(userId)).toString();
    return _LoginResult(token: token, accountIdHash: accountIdHash);
  }

  Future<List<LibreLinkUpPatient>> _fetchPatients(
    LibreLinkUpRegion region, {
    required String? token,
    required String? accountIdHash,
  }) async {
    final uri = Uri.parse('${region.baseUrl}/llu/connections');
    final response = await _http.get(
      uri,
      headers: _headers(token: token, accountIdHash: accountIdHash),
    );
    if (response.statusCode != 200) {
      throw LibreLinkUpException(
          'Falha ao listar pacientes do LibreLinkUp (HTTP ${response.statusCode}).');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final rows = body['data'] as List<dynamic>? ?? const [];
    return rows
        .cast<Map<String, dynamic>>()
        .map((row) => LibreLinkUpPatient(
              patientId: row['patientId'] as String? ?? '',
              firstName: row['firstName'] as String? ?? '',
              lastName: row['lastName'] as String? ?? '',
            ))
        .where((patient) => patient.patientId.isNotEmpty)
        .toList();
  }
}

class _LoginResult {
  _LoginResult({this.token, this.accountIdHash, this.redirectRegion});
  final String? token;
  final String? accountIdHash;
  final LibreLinkUpRegion? redirectRegion;
}

/// The only place LibreLinkUp credentials and the resulting session are
/// persisted: OS-level secure storage (Android Keystore-backed), never
/// SharedPreferences/UserProfile/SQLite. See docs/fsm/cgm.mmd.
class LibreLinkUpCredentialStore {
  LibreLinkUpCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _keyEmail = 'librelinkup_email';
  static const _keyPassword = 'librelinkup_password';
  static const _keyRegion = 'librelinkup_region';
  static const _keyPatientId = 'librelinkup_patient_id';
  static const _keyPatientName = 'librelinkup_patient_name';
  static const _keyLastSyncedAt = 'librelinkup_last_synced_at';

  Future<void> save({
    required String email,
    required String password,
    required String regionCode,
    required String patientId,
    required String patientName,
  }) async {
    await _storage.write(key: _keyEmail, value: email);
    await _storage.write(key: _keyPassword, value: password);
    await _storage.write(key: _keyRegion, value: regionCode);
    await _storage.write(key: _keyPatientId, value: patientId);
    await _storage.write(key: _keyPatientName, value: patientName);
  }

  Future<bool> get isConnected async =>
      (await _storage.read(key: _keyEmail)) != null;

  Future<
      ({
        String email,
        String password,
        String regionCode,
        String patientId,
        String patientName,
      })?> load() async {
    final email = await _storage.read(key: _keyEmail);
    final password = await _storage.read(key: _keyPassword);
    final patientId = await _storage.read(key: _keyPatientId);
    if (email == null || password == null || patientId == null) return null;
    return (
      email: email,
      password: password,
      regionCode: await _storage.read(key: _keyRegion) ?? 'LA',
      patientId: patientId,
      patientName: await _storage.read(key: _keyPatientName) ?? '',
    );
  }

  Future<DateTime?> get lastSyncedAt async {
    final raw = await _storage.read(key: _keyLastSyncedAt);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setLastSyncedAt(DateTime at) =>
      _storage.write(key: _keyLastSyncedAt, value: at.toIso8601String());

  Future<void> clear() async {
    await _storage.delete(key: _keyEmail);
    await _storage.delete(key: _keyPassword);
    await _storage.delete(key: _keyRegion);
    await _storage.delete(key: _keyPatientId);
    await _storage.delete(key: _keyPatientName);
    await _storage.delete(key: _keyLastSyncedAt);
  }
}
