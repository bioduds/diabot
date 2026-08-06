import 'package:diabai/cgm/glucose_estimator.dart';
import 'package:diabai/engines/clinical_reasoning_layer.dart';
import 'package:diabai/engines/hypothesis_engine.dart';
import 'package:diabai/engines/physiological_state_engine.dart';
import 'package:flutter_test/flutter_test.dart';

GlucoseEstimate _estimate({
  required double observed,
  required double estimatedNow,
  required double velocity,
  required double residual,
  required double confidence,
}) =>
    GlucoseEstimate(
      observed: observed,
      estimated: estimatedNow,
      estimatedNow: estimatedNow,
      velocity: velocity,
      confidence: confidence,
      sigma: 3,
      lagMinutes: 10,
      residual: residual,
    );

void main() {
  test('assesses a true hypoglycemia reading as its own dominant hypothesis', () {
    final assessment = ClinicalReasoningLayer.assess(
      estimate: _estimate(
        observed: 58,
        estimatedNow: 58,
        velocity: -0.1,
        residual: 1,
        confidence: 0.95,
      ),
      at: DateTime.utc(2026, 8, 3, 12),
      stack: const [],
    );

    expect(
      assessment.dominantHypothesis?.type,
      ClinicalHypothesisType.trueHypoglycemia,
    );
    expect(assessment.confidence.tier, 'alta');
    expect(assessment.contradictions.hasContradiction, isFalse);
    expect(assessment.physiologicalPhase, PhysiologicalPhase.stabilizing);
  });

  test(
      'ranks sensorLag ahead of a discounted hypoglycemia reading and flags '
      'the matching contradiction', () {
    final at = DateTime.utc(2026, 8, 3, 12);
    final assessment = ClinicalReasoningLayer.assess(
      estimate: _estimate(
        observed: 85,
        estimatedNow: 65,
        velocity: -3,
        residual: 20,
        confidence: 0.3,
      ),
      at: at,
      stack: const [],
      // Establishes an accelerating drop (velocity moving from 0 to -3 over
      // 6 minutes = -0.5 mg/dL/min^2), matching ContradictionEngine's
      // kalmanMuchLowerAcceleratingDrop pattern.
      previousEstimate: _estimate(
        observed: 100,
        estimatedNow: 100,
        velocity: 0,
        residual: 0,
        confidence: 0.9,
      ),
      previousAt: at.subtract(const Duration(minutes: 6)),
    );

    expect(
      assessment.dominantHypothesis?.type,
      ClinicalHypothesisType.sensorLag,
    );
    expect(
      assessment.hypotheses.any(
        (h) => h.type == ClinicalHypothesisType.trueHypoglycemia,
      ),
      isTrue,
    );
    expect(
      assessment.contradictions.hasPattern('kalmanMuchLowerAcceleratingDrop'),
      isTrue,
    );
    // A fast, near-hypo fall stays physiologically at-risk even when the
    // dominant hypothesis attributes it to sensor lag.
    expect(assessment.physiologicalPhase, PhysiologicalPhase.hypoRisk);
  });

  test('assesses a falling, low-confidence reading without symptoms as compression artifact', () {
    final assessment = ClinicalReasoningLayer.assess(
      estimate: _estimate(
        observed: 105,
        estimatedNow: 100,
        velocity: -1.0,
        residual: 5,
        confidence: 0.4,
      ),
      at: DateTime.utc(2026, 8, 3, 12),
      stack: const [],
    );

    expect(
      assessment.dominantHypothesis?.type,
      ClinicalHypothesisType.compressionArtifact,
    );
    expect(assessment.confidence.tier, 'media');
    expect(assessment.contradictions.hasContradiction, isFalse);
  });

  test('produces no dominant hypothesis for a stable, normal-range reading', () {
    final assessment = ClinicalReasoningLayer.assess(
      estimate: _estimate(
        observed: 100,
        estimatedNow: 100,
        velocity: 0.1,
        residual: 1,
        confidence: 0.95,
      ),
      at: DateTime.utc(2026, 8, 3, 12),
      stack: const [],
    );

    expect(assessment.hypotheses, isEmpty);
    expect(assessment.dominantHypothesis, isNull);
    expect(assessment.contradictions.hasContradiction, isFalse);
    expect(assessment.physiologicalPhase, PhysiologicalPhase.stabilizing);
  });
}
