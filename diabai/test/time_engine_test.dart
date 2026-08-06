import 'dart:convert';

import 'package:diabai/events.dart';
import 'package:diabai/time_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryHistory implements RecentEventReader {
  _MemoryHistory(this.rowsByType);

  final Map<String, List<Map<String, dynamic>>> rowsByType;

  @override
  Future<List<Map<String, dynamic>>> recentEventsOfType(
    String type,
    Duration within,
  ) async => rowsByType[type] ?? const [];
}

Map<String, dynamic> storedEvent(
  DateTime createdAt,
  Map<String, dynamic> payload,
) =>
    {
      'created_at': createdAt.toIso8601String(),
      'payload': jsonEncode(payload),
    };

void main() {
  final now = DateTime.utc(2026, 7, 30, 12);

  test('builds temporal context from the current stack and stored history', () async {
    final engine = TimeEngine(
      now: () => now,
      history: _MemoryHistory({
        'insulin': [storedEvent(now.subtract(const Duration(minutes: 40)), {'dose': 20})],
        'exercise': [
          storedEvent(now.subtract(const Duration(minutes: 30)), {'intensity': 'intensa'}),
        ],
        'meal': [storedEvent(now.subtract(const Duration(hours: 2)), {'carbsGrams': 80})],
      }),
    );

    final context = await engine.buildContext([
      EventInstance(
        type: EventType.glucose,
        data: {'value': 77},
        createdAt: now,
      ),
    ]);

    expect(context.count(EventType.glucose, const Duration(minutes: 15)), 1);
    expect(context.has(EventType.insulin, const Duration(hours: 1)), isTrue);
    expect(context.has(EventType.meal, const Duration(hours: 1)), isFalse);
    expect(context.has(EventType.meal, const Duration(hours: 4)), isTrue);
    expect(
      context.hasFieldValue(
        EventType.exercise,
        'intensity',
        'intensa',
        const Duration(hours: 1),
      ),
      isTrue,
    );
  });

  test('raises emergency risk from temporal insulin and intense exercise', () async {
    final engine = TimeEngine(
      now: () => now,
      history: _MemoryHistory({
        'insulin': [storedEvent(now.subtract(const Duration(minutes: 40)), {'dose': 20})],
        'exercise': [
          storedEvent(now.subtract(const Duration(minutes: 30)), {'intensity': 'intensa'}),
        ],
      }),
    );
    final assessment = await EmergencyEngine(
      temporalContextProvider: engine,
    ).assess([
      EventInstance(
        type: EventType.glucose,
        data: {'value': 77},
        createdAt: now,
      ),
    ]);

    expect(assessment.isEmergency, isTrue);
    expect(assessment.severity, greaterThanOrEqualTo(EmergencyEngine.scoreThreshold));
    expect(assessment.usedTemporalContext, isTrue);
    expect(assessment.reason, contains('insulina rápida recente'));
    expect(assessment.reason, contains('exercício intenso recente'));
  });

  test('reports elapsed time since the most recent event of each kind', () async {
    final engine = TimeEngine(
      now: () => now,
      history: _MemoryHistory({
        'insulin': [
          storedEvent(now.subtract(const Duration(hours: 2)),
              {'dose': 4, 'insulinType': 'rapida'}),
          storedEvent(now.subtract(const Duration(hours: 8)),
              {'dose': 10, 'insulinType': 'basal'}),
        ],
        'meal': [storedEvent(now.subtract(const Duration(hours: 1)), {'carbsGrams': 40})],
        'exercise': [
          storedEvent(now.subtract(const Duration(minutes: 45)), {'intensity': 'leve'}),
        ],
        'symptoms': [
          storedEvent(now.subtract(const Duration(minutes: 10)), {'symptomType': 'hypo'}),
        ],
      }),
    );

    final context = await engine.buildContext(const []);

    expect(context.timeSinceBolus, const Duration(hours: 2));
    expect(context.timeSinceBasal, const Duration(hours: 8));
    expect(context.timeSinceMeal, const Duration(hours: 1));
    expect(context.timeSinceExercise, const Duration(minutes: 45));
    expect(context.timeSinceSymptoms, const Duration(minutes: 10));
  });

  test('reports null time-since when no matching event exists', () async {
    final engine = TimeEngine(now: () => now, history: _MemoryHistory(const {}));

    final context = await engine.buildContext(const []);

    expect(context.timeSinceBolus, isNull);
    expect(context.timeSinceBasal, isNull);
    expect(context.timeSinceMeal, isNull);
    expect(context.timeSinceExercise, isNull);
    expect(context.timeSinceSymptoms, isNull);
  });
}