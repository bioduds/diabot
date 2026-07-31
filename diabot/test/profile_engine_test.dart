import 'dart:convert';

import 'package:diabai/events.dart';
import 'package:diabai/profile_engine.dart';
import 'package:diabai/time_engine.dart';
import 'package:diabai/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemorySnapshotGateway implements ProfileSnapshotGateway {
  Map<String, dynamic>? snapshot;
  var saves = 0;

  @override
  Future<Map<String, dynamic>?> loadProfileSnapshot() async => snapshot;

  @override
  Future<void> saveProfileSnapshot(Map<String, dynamic> value) async {
    snapshot = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    saves++;
  }
}

class _EmptyHistory implements RecentEventReader {
  @override
  Future<List<Map<String, dynamic>>> recentEventsOfType(
    String type,
    Duration within,
  ) async =>
      const [];
}

void main() {
  final now = DateTime.utc(2026, 7, 30, 12);

  ProfileEngine engine(
    _MemorySnapshotGateway gateway, {
    UserProfile? profile,
    Future<void> Function(UserProfile)? saveProfile,
  }) =>
      ProfileEngine(
        snapshotGateway: gateway,
        loadCurrentProfile: () async => profile ?? UserProfile(),
        saveCurrentProfile: saveProfile ?? (_) async {},
        now: () => now,
      );

  test('passively updates profile facts, score, and confidence', () async {
    final gateway = _MemorySnapshotGateway();
    final result = await engine(gateway).enrich([
      EventInstance(
        type: EventType.profile,
        data: const {
          'diabetesType': 'DM1',
          'weightKg': 107,
          'cgm': 'Libre',
          'insulinType': 'Fiasp',
          '_parserConfidence': 0.82,
        },
        createdAt: now,
      ),
    ]);

    expect(result.changed, isTrue);
    expect(result.profile.value('diabetesType'), 'DM1');
    expect(result.profile.value('weightKg'), 107);
    expect(result.profile.value('cgm'), 'Libre');
    expect(result.profile.value('insulinTypes'), 'Fiasp');
    expect(result.profile.confidence('diabetesType'), 0.82);
    expect(result.profile.completenessScore, 43);
    expect(result.profile.missingInformation, contains('heightCm'));
  });

  test('persists and retrieves the profile snapshot through the SQLite gateway',
      () async {
    final gateway = _MemorySnapshotGateway();
    await engine(gateway).enrich([
      EventInstance(
        type: EventType.profile,
        data: const {'diabetesType': 'DM2', '_parserConfidence': 0.9},
        createdAt: now,
      ),
    ]);
    final retrieved = await engine(gateway).enrich(const []);

    expect(gateway.saves, 1);
    expect(retrieved.changed, isFalse);
    expect(retrieved.profile.value('diabetesType'), 'DM2');
    expect(retrieved.profile.confidence('diabetesType'), 0.9);
  });

  test(
      'seeds authenticated identity facts without changing clinical completeness',
      () async {
    final result = await engine(
      _MemorySnapshotGateway(),
      profile: UserProfile(
        nome: 'Ana Silva',
        email: 'ana@example.com',
        fotoUrl: 'https://example.com/ana.jpg',
      ),
    ).enrich(const []);

    expect(result.profile.value('name'), 'Ana Silva');
    expect(result.profile.value('email'), 'ana@example.com');
    expect(result.profile.value('photoUrl'), 'https://example.com/ana.jpg');
    expect(result.profile.completenessScore, 0);
  });

  test(
      'persists a locally selected photo without changing clinical completeness',
      () async {
    final gateway = _MemorySnapshotGateway();
    final profile = UserProfile(fotoUrl: 'https://example.com/ana.jpg');
    var saved = false;
    final engineWithPhoto = engine(
      gateway,
      profile: profile,
      saveProfile: (_) async => saved = true,
    );
    await engineWithPhoto.enrich(const []);
    final result = await engineWithPhoto.saveLocalPhoto('/local/ana.jpg');

    expect(saved, isTrue);
    expect(profile.fotoUrl, '/local/ana.jpg');
    expect(result.profile.value('photoUrl'), '/local/ana.jpg');
    expect(result.profile.completenessScore, 0);
  });

  test('shares current events with Time Engine without changing temporal facts',
      () async {
    final insulin = EventInstance(
      type: EventType.insulin,
      data: const {'insulinType': 'Fiasp', 'dose': 4},
      createdAt: now.subtract(const Duration(minutes: 20)),
    );
    final profile = await engine(_MemorySnapshotGateway()).enrich([insulin]);
    final temporal = await TimeEngine(
      history: _EmptyHistory(),
      now: () => now,
    ).buildContext([insulin]);

    expect(profile.profile.value('insulinTypes'), 'Fiasp');
    expect(temporal.has(EventType.insulin, const Duration(hours: 1)), isTrue);
  });

  test('adds known hypoglycemia unawareness to Emergency Engine context',
      () async {
    final profile = await engine(_MemorySnapshotGateway()).enrich([
      EventInstance(
        type: EventType.profile,
        data: const {
          'hypoglycemiaUnawareness': true,
          '_parserConfidence': 0.9,
        },
        createdAt: now,
      ),
    ]);
    final assessment = await EmergencyEngine().assess(
      [
        EventInstance(
          type: EventType.glucose,
          data: const {'value': 77},
          createdAt: now,
        ),
        EventInstance(
          type: EventType.symptoms,
          data: const {'symptomType': 'hypo'},
          createdAt: now,
        ),
      ],
      profileContext: profile.profile,
    );

    expect(assessment.isEmergency, isTrue);
    expect(
        assessment.reason, contains('histórico de hipoglicemia não percebida'));
  });

  test('exposes missing profile information to Knowledge Engine without asking',
      () async {
    final profile = await engine(_MemorySnapshotGateway()).enrich([
      EventInstance(
        type: EventType.profile,
        data: const {'diabetesType': 'DM1'},
        createdAt: now,
      ),
    ]);
    final missing = KnowledgeEngine.missingProfileInformation(profile.profile);

    expect(missing, isNot(contains('diabetesType')));
    expect(missing, contains('cgm'));
    expect(missing, hasLength(FsmContract.profileFields.length - 1));
  });
}
