import 'package:diabai/engines/contradiction_engine.dart';
import 'package:diabai/engines/evidence_fusion_engine.dart';
import 'package:diabai/engines/hypothesis_engine.dart';
import 'package:diabai/engines/sensor_reliability_engine.dart';
import 'package:flutter_test/flutter_test.dart';

EvidenceSet _evidence({
  double observed = 100,
  double estimatedNow = 100,
  double velocity = 0,
  double acceleration = 0,
  bool hasHypoSymptoms = false,
  bool hasHyperSymptoms = false,
}) =>
    EvidenceSet(
      referenceTime: DateTime.utc(2026, 8, 3, 12),
      glucoseEvidence: GlucoseEvidence(
        observed: observed,
        estimatedNow: estimatedNow,
        residual: observed - estimatedNow,
        kalmanConfidence: 0.9,
      ),
      trendEvidence: TrendEvidence(
        velocity: velocity,
        acceleration: acceleration,
      ),
      symptomEvidence: SymptomEvidence(
        hasHypoSymptoms: hasHypoSymptoms,
        hasHyperSymptoms: hasHyperSymptoms,
      ),
      insulinEvidence: const InsulinEvidence(),
      exerciseEvidence: const ExerciseEvidence(),
      mealEvidence: const MealEvidence(),
    );

const _reliable = SensorReliability(
  confidence: 0.95,
  probableLag: false,
  probableCompression: false,
  probableSensorError: false,
);

void main() {
  test('flags sensorHighStrongSymptoms for a high reading with hypo symptoms', () {
    final report = ContradictionEngine.detect(
      _evidence(estimatedNow: 220, hasHypoSymptoms: true),
      _reliable,
      const [],
    );

    expect(report.hasPattern('sensorHighStrongSymptoms'), isTrue);
    expect(report.flags.single.rationale, contains('220'));
  });

  test('flags kalmanMuchLowerAcceleratingDrop and cites a corroborating hypothesis', () {
    final report = ContradictionEngine.detect(
      _evidence(observed: 100, estimatedNow: 80, velocity: -2, acceleration: -0.5),
      _reliable,
      const [
        ClinicalHypothesis(
          type: ClinicalHypothesisType.sensorLag,
          confidence: 0.62,
          rationale: 'test',
        ),
      ],
    );

    expect(report.hasPattern('kalmanMuchLowerAcceleratingDrop'), isTrue);
    expect(report.flags.single.rationale, contains('62%'));
  });

  test('kalmanMuchLowerAcceleratingDrop omits corroboration without a matching hypothesis', () {
    final report = ContradictionEngine.detect(
      _evidence(observed: 100, estimatedNow: 80, velocity: -2, acceleration: -0.5),
      _reliable,
      const [],
    );

    expect(report.flags.single.rationale, isNot(contains('%')));
  });

  test('flags sensorNormalWithSymptoms for a normal reading with reported symptoms', () {
    final report = ContradictionEngine.detect(
      _evidence(estimatedNow: 100, hasHyperSymptoms: true),
      _reliable,
      const [],
    );

    expect(report.hasPattern('sensorNormalWithSymptoms'), isTrue);
  });

  test('produces no flags for consistent evidence', () {
    final report = ContradictionEngine.detect(
      _evidence(estimatedNow: 60, velocity: -0.5),
      _reliable,
      const [],
    );

    expect(report.hasContradiction, isFalse);
  });

  test('does not flag an accelerating drop below the gap threshold', () {
    final report = ContradictionEngine.detect(
      _evidence(observed: 100, estimatedNow: 92, velocity: -2, acceleration: -0.5),
      _reliable,
      const [],
    );

    expect(report.hasPattern('kalmanMuchLowerAcceleratingDrop'), isFalse);
  });
}
