import 'dart:convert';

import 'package:diabot/events.dart';
import 'package:diabot/time_engine.dart';
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
}