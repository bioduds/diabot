import 'dart:convert';

import 'package:diabai/engines/hypothesis_engine.dart';
import 'package:diabai/engines/physiological_state_engine.dart';
import 'package:diabai/events.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 7.5: EmergencyEngine now replays recent stored `glucose` events
/// through a real [GlucoseEstimator] instead of building a synthetic
/// zero-velocity/full-confidence estimate (see events.dart's
/// `_buildRealEstimate`). These tests exercise `assessment.clinicalAssessment`
/// with genuine multi-reading histories — `emergency_engine_regression_test`
/// remains the source of truth for `isEmergency`/`severity`, which this
/// change must never affect (`_score()` is untouched).
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

/// Builds fake stored `glucose` rows ending 5 minutes before "now" (each
/// [stepMinutes] apart, oldest first), the exact shape
/// `EmergencyEngine._buildRealEstimate` expects from `recentEventsOfType`.
List<Map<String, dynamic>> _glucoseHistory(
  List<double> values, {
  int stepMinutes = 5,
}) {
  final now = DateTime.now();
  final anchor = now.subtract(const Duration(minutes: 5));
  return [
    for (var i = 0; i < values.length; i++)
      {
        'created_at': anchor
            .subtract(Duration(minutes: (values.length - 1 - i) * stepMinutes))
            .toIso8601String(),
        'payload': jsonEncode({'value': values[i]}),
      },
  ];
}

EventInstance _glucose(double value) => EventInstance(
      type: EventType.glucose,
      data: {'value': value},
    );

void main() {
  test(
      'no glucose history at all (cold start) still yields a usable '
      'assessment, with a real — not hardcoded — confidence', () async {
    final assessment = await EmergencyEngine().assess([_glucose(100)]);

    final clinical = assessment.clinicalAssessment!;
    // A single reading can't know its own velocity yet, so the Kalman
    // filter is genuinely unsure of "right now" — this is expected, not a
    // bug, and mirrors GlucoseChartPage's identical cold-start behavior.
    expect(clinical.confidence.overall, lessThan(1.0));
    expect(clinical.evidence.glucoseEvidence.residual, 0.0);
    expect(clinical.evidence.trendEvidence.velocity, 0.0);
  });

  test(
      'a stable multi-reading history followed by an unremarkable reading '
      'produces no dominant hypothesis', () async {
    final engine = EmergencyEngine(
      history: _FakeHistory({
        'glucose': _glucoseHistory(List.filled(11, 150.0)),
      }),
    );

    final assessment = await engine.assess([_glucose(150)]);

    final clinical = assessment.clinicalAssessment!;
    expect(clinical.dominantHypothesis, isNull);
    expect(assessment.isEmergency, isFalse);
  });

  test(
      'a smooth, sustained decline reaching a low value yields '
      'trueHypoglycemia at alta confidence, driven by real velocity/residual',
      () async {
    final engine = EmergencyEngine(
      history: _FakeHistory({
        'glucose': _glucoseHistory(
          [225, 210, 195, 180, 165, 150, 135, 120, 105, 90, 75, 60],
        ),
      }),
    );

    final assessment = await engine.assess([_glucose(45)]);

    final clinical = assessment.clinicalAssessment!;
    expect(
      clinical.dominantHypothesis?.type,
      ClinicalHypothesisType.trueHypoglycemia,
    );
    expect(clinical.confidence.tier, 'alta');
    expect(clinical.physiologicalPhase, PhysiologicalPhase.hypoRisk);
    expect(clinical.evidence.trendEvidence.velocity, lessThan(-1.0));
    // The band/symptom formula (_score, untouched by Phase 7.5) already
    // flags glucose this low (<55 mg/dL) on its own — confirms the real
    // estimate is additive evidence, not a replacement for the existing
    // gate.
    expect(assessment.isEmergency, isTrue);
  });
}
