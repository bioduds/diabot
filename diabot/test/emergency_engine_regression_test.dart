import 'dart:convert';

import 'package:diabai/events.dart';
import 'package:flutter_test/flutter_test.dart';

/// Locks in every scenario the pre-Phase-6 weighted-sum `EmergencyEngine`
/// formula triggers (or deliberately does not trigger) on today, so that
/// Phase 6's additive ClinicalReasoningLayer corroboration can never cause a
/// regression: every `isEmergency: true` case here must still be true
/// afterward (Option A only ever adds to the score, never subtracts).
class _FakeHistory implements RecentEventReader {
  _FakeHistory(this.rows);

  final Map<String, List<Map<String, dynamic>>> rows;

  @override
  Future<List<Map<String, dynamic>>> recentEventsOfType(
    String type,
    Duration within,
  ) async =>
      rows[type] ?? const [];
}

class _FakeProfileContext implements ProfileContext {
  const _FakeProfileContext({this.hypoglycemiaUnawareness = false});

  final bool hypoglycemiaUnawareness;

  @override
  Object? value(String field) =>
      field == 'hypoglycemiaUnawareness' ? hypoglycemiaUnawareness : null;

  @override
  double confidence(String field) =>
      field == 'hypoglycemiaUnawareness' && hypoglycemiaUnawareness ? 0.9 : 0.0;

  @override
  int get completenessScore => 0;

  @override
  List<String> get missingInformation => const [];
}

final _at = DateTime.utc(2026, 8, 3, 12);

EventInstance _glucose(double value) => EventInstance(
      type: EventType.glucose,
      data: {'value': value},
      createdAt: _at,
    );

EventInstance _symptom(String symptomType) => EventInstance(
      type: EventType.symptoms,
      data: {'symptomType': symptomType},
      createdAt: _at,
    );

Map<String, dynamic> _row(Map<String, dynamic> payload) => {
      'created_at': _at.toIso8601String(),
      'payload': jsonEncode(payload),
    };

void main() {
  test('glucose below 55 alone reaches the threshold', () async {
    final assessment = await EmergencyEngine().assess([_glucose(50)]);

    expect(assessment.isEmergency, isTrue);
    expect(assessment.severity, closeTo(0.6, 1e-9));
    expect(assessment.reason, contains('glicemia muito baixa'));
  });

  test('glucose between 55 and 70 alone does not reach the threshold', () async {
    final assessment = await EmergencyEngine().assess([_glucose(60)]);

    expect(assessment.isEmergency, isFalse);
    expect(assessment.severity, closeTo(0.3, 1e-9));
  });

  test('glucose between 55 and 70 with hypo symptoms reaches the threshold', () async {
    final assessment = await EmergencyEngine().assess([
      _glucose(60),
      _symptom('hypo'),
    ]);

    expect(assessment.isEmergency, isTrue);
    expect(assessment.severity, closeTo(0.6, 1e-9));
  });

  test('glucose in the 70-90 attention band alone does not reach the threshold', () async {
    final assessment = await EmergencyEngine().assess([_glucose(80)]);

    expect(assessment.isEmergency, isFalse);
    expect(assessment.severity, closeTo(0.2, 1e-9));
  });

  test(
      'attention-band glucose with hypo symptoms and recent fast insulin '
      'reaches the threshold', () async {
    final engine = EmergencyEngine(
      history: _FakeHistory({
        'insulin': [_row({'dose': 10})],
      }),
    );

    final assessment = await engine.assess([
      _glucose(80),
      _symptom('hypo'),
    ]);

    expect(assessment.isEmergency, isTrue);
    // 0.2 + 0.3 + 0.25 = 0.75 from the original signals, clamped to 1.0 once
    // ClinicalReasoningLayer's sensorNormalWithSymptoms contradiction (a
    // "normal-ish" reading with reported symptoms) adds its 0.25 bonus.
    expect(assessment.severity, 1.0);
    expect(assessment.reason, contains('insulina rápida recente'));
  });

  test('glucose above 300 alone does not reach the threshold', () async {
    final assessment = await EmergencyEngine().assess([_glucose(310)]);

    expect(assessment.isEmergency, isFalse);
    expect(assessment.severity, closeTo(0.5, 1e-9));
  });

  test('glucose above 300 with hyperglycemia symptoms reaches the threshold', () async {
    final assessment = await EmergencyEngine().assess([
      _glucose(310),
      _symptom('hyper'),
    ]);

    expect(assessment.isEmergency, isTrue);
    expect(assessment.severity, closeTo(0.7, 1e-9));
  });

  test(
      'glucose above 250 with hyper symptoms and known hypoglycemia '
      'unawareness reaches the threshold', () async {
    final assessment = await EmergencyEngine().assess(
      [_glucose(260), _symptom('hyper')],
      profileContext: const _FakeProfileContext(hypoglycemiaUnawareness: true),
    );

    expect(assessment.isEmergency, isTrue);
    expect(assessment.severity, closeTo(0.6, 1e-9));
  });

  test('known hypoglycemia unawareness alone does not reach the threshold', () async {
    final assessment = await EmergencyEngine().assess(
      const [],
      profileContext: const _FakeProfileContext(hypoglycemiaUnawareness: true),
    );

    expect(assessment.isEmergency, isFalse);
    expect(assessment.severity, closeTo(0.15, 1e-9));
  });

  test('recent intense exercise with glucose below 100 alone does not reach the threshold', () async {
    final engine = EmergencyEngine(
      history: _FakeHistory({
        'exercise': [_row({'intensity': 'intensa'})],
      }),
    );

    final assessment = await engine.assess([_glucose(95)]);

    expect(assessment.isEmergency, isFalse);
    expect(assessment.severity, closeTo(0.15, 1e-9));
  });

  test(
      'recent fast insulin with low-normal glucose and known hypoglycemia '
      'unawareness reaches the threshold', () async {
    final engine = EmergencyEngine(
      history: _FakeHistory({
        'insulin': [_row({'dose': 10})],
      }),
    );

    final assessment = await engine.assess(
      [_glucose(85)],
      profileContext: const _FakeProfileContext(hypoglycemiaUnawareness: true),
    );

    expect(assessment.isEmergency, isTrue);
    expect(assessment.severity, closeTo(0.6, 1e-9));
  });

  test('recent fast insulin without a qualifying glucose or symptom contributes nothing', () async {
    final engine = EmergencyEngine(
      history: _FakeHistory({
        'insulin': [_row({'dose': 10})],
      }),
    );

    final assessment = await engine.assess([_glucose(150)]);

    expect(assessment.isEmergency, isFalse);
    expect(assessment.severity, 0);
  });

  test('recent intense exercise at exactly 100 mg/dL contributes nothing', () async {
    final engine = EmergencyEngine(
      history: _FakeHistory({
        'exercise': [_row({'intensity': 'intensa'})],
      }),
    );

    final assessment = await engine.assess([_glucose(100)]);

    expect(assessment.isEmergency, isFalse);
    expect(assessment.severity, 0);
  });

  test('compounding signals clamp severity at 1.0', () async {
    final engine = EmergencyEngine(
      history: _FakeHistory({
        'insulin': [_row({'dose': 10})],
        'exercise': [_row({'intensity': 'intensa'})],
      }),
    );

    final assessment = await engine.assess(
      [_glucose(40), _symptom('hypo')],
      profileContext: const _FakeProfileContext(hypoglycemiaUnawareness: true),
    );

    expect(assessment.isEmergency, isTrue);
    expect(assessment.severity, 1.0);
  });

  test('no signals at all produces zero severity and no emergency', () async {
    final assessment = await EmergencyEngine().assess(const []);

    expect(assessment.isEmergency, isFalse);
    expect(assessment.severity, 0);
    expect(assessment.reason, isEmpty);
  });

  test(
      'Phase 6 enhancement: a normal-range reading with hypo symptoms and '
      'recent insulin now reaches the threshold via the added '
      'ClinicalReasoningLayer corroboration', () async {
    // Pre-Phase-6 this scored only 0.3 (symptom) + 0.25 (insulin) = 0.55,
    // just under the 0.6 threshold — a real gap the sensorNormalWithSymptoms
    // contradiction (glucose reads normal, but symptoms say otherwise) now
    // closes without changing any of the original band/signal weights.
    final engine = EmergencyEngine(
      history: _FakeHistory({
        'insulin': [_row({'dose': 10})],
      }),
    );

    final assessment = await engine.assess([
      _glucose(100),
      _symptom('hypo'),
    ]);

    expect(assessment.isEmergency, isTrue);
    expect(assessment.severity, closeTo(0.8, 1e-9));
    expect(assessment.reason, contains('divergência'));
  });
}
