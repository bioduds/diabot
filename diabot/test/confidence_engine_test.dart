import 'package:diabai/engines/confidence_engine.dart';
import 'package:diabai/engines/contradiction_engine.dart';
import 'package:diabai/engines/hypothesis_engine.dart';
import 'package:diabai/engines/sensor_reliability_engine.dart';
import 'package:flutter_test/flutter_test.dart';

const _reliable = SensorReliability(
  confidence: 0.95,
  probableLag: false,
  probableCompression: false,
  probableSensorError: false,
);

void main() {
  test('bucketed as alta for a high-confidence hypothesis with no contradictions', () {
    final confidence = ConfidenceEngine.compute(
      const [
        ClinicalHypothesis(
          type: ClinicalHypothesisType.trueHypoglycemia,
          confidence: 0.9,
          rationale: 'test',
        ),
      ],
      _reliable,
      const ContradictionReport(),
    );

    expect(confidence.overall, 0.9);
    expect(confidence.tier, 'alta');
    expect(confidence.perHypothesis[ClinicalHypothesisType.trueHypoglycemia], 0.9);
  });

  test('each contradiction flag lowers overall confidence', () {
    final confidence = ConfidenceEngine.compute(
      const [
        ClinicalHypothesis(
          type: ClinicalHypothesisType.meal,
          confidence: 0.9,
          rationale: 'test',
        ),
      ],
      _reliable,
      const ContradictionReport(flags: [
        ContradictionFlag(pattern: 'sensorNormalWithSymptoms', rationale: 'x'),
      ]),
    );

    expect(confidence.overall, closeTo(0.75, 1e-9));
  });

  test('an unreliable sensor discounts overall confidence before the contradiction penalty', () {
    const unreliable = SensorReliability(
      confidence: 0.5,
      probableLag: true,
      probableCompression: false,
      probableSensorError: false,
    );

    final confidence = ConfidenceEngine.compute(
      const [
        ClinicalHypothesis(
          type: ClinicalHypothesisType.sensorLag,
          confidence: 0.8,
          rationale: 'test',
        ),
      ],
      unreliable,
      const ContradictionReport(),
    );

    expect(confidence.overall, closeTo(0.8 * 0.85, 1e-9));
  });

  test('bucketed as baixa with no hypotheses at all', () {
    final confidence = ConfidenceEngine.compute(
      const [],
      _reliable,
      const ContradictionReport(),
    );

    expect(confidence.overall, 0.0);
    expect(confidence.tier, 'baixa');
  });

  test('bucketed as media for a mid-range confidence', () {
    final confidence = ConfidenceEngine.compute(
      const [
        ClinicalHypothesis(
          type: ClinicalHypothesisType.stress,
          confidence: 0.6,
          rationale: 'test',
        ),
      ],
      _reliable,
      const ContradictionReport(),
    );

    expect(confidence.tier, 'media');
  });

  test('overall confidence never goes below zero', () {
    final confidence = ConfidenceEngine.compute(
      const [
        ClinicalHypothesis(
          type: ClinicalHypothesisType.meal,
          confidence: 0.2,
          rationale: 'test',
        ),
      ],
      _reliable,
      const ContradictionReport(flags: [
        ContradictionFlag(pattern: 'a', rationale: 'x'),
        ContradictionFlag(pattern: 'b', rationale: 'x'),
        ContradictionFlag(pattern: 'c', rationale: 'x'),
      ]),
    );

    expect(confidence.overall, 0.0);
  });
}
