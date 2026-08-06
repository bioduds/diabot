import 'package:diabai/engines/evidence_fusion_engine.dart';
import 'package:diabai/engines/hypothesis_engine.dart';
import 'package:diabai/engines/physiological_state_engine.dart';
import 'package:flutter_test/flutter_test.dart';

EvidenceSet _evidence({
  double estimatedNow = 100,
  double velocity = 0,
  double acceleration = 0,
  bool hasActiveCarbs = false,
  bool hasActiveBolus = false,
}) =>
    EvidenceSet(
      referenceTime: DateTime.utc(2026, 8, 3, 12),
      glucoseEvidence: GlucoseEvidence(
        observed: estimatedNow,
        estimatedNow: estimatedNow,
        residual: 0,
        kalmanConfidence: 0.9,
      ),
      trendEvidence: TrendEvidence(velocity: velocity, acceleration: acceleration),
      symptomEvidence: const SymptomEvidence(),
      insulinEvidence: InsulinEvidence(
        timeSinceBolus: hasActiveBolus ? const Duration(hours: 1) : null,
      ),
      exerciseEvidence: const ExerciseEvidence(),
      mealEvidence: MealEvidence(
        timeSinceMeal: hasActiveCarbs ? const Duration(hours: 1) : null,
      ),
    );

void main() {
  test('classifies hypoRisk for a low, falling reading', () {
    final phase = PhysiologicalStateEngine.classify(
      _evidence(estimatedNow: 75, velocity: -1.0),
      const [],
    );

    expect(phase, PhysiologicalPhase.hypoRisk);
  });

  test('hypoRisk takes priority over acceleratingDrop near the threshold', () {
    final phase = PhysiologicalStateEngine.classify(
      _evidence(estimatedNow: 75, velocity: -1.0, acceleration: -0.5),
      const [],
    );

    expect(phase, PhysiologicalPhase.hypoRisk);
  });

  test('classifies acceleratingDrop for a fast, accelerating fall above the hypo threshold', () {
    final phase = PhysiologicalStateEngine.classify(
      _evidence(estimatedNow: 120, velocity: -1.0, acceleration: -0.5),
      const [],
    );

    expect(phase, PhysiologicalPhase.acceleratingDrop);
  });

  test('classifies recovering for a rising trend after a recent low hypothesis', () {
    final phase = PhysiologicalStateEngine.classify(
      _evidence(estimatedNow: 90, velocity: 1.0),
      const [
        ClinicalHypothesis(
          type: ClinicalHypothesisType.trueHypoglycemia,
          confidence: 0.8,
          rationale: 'test',
        ),
      ],
    );

    expect(phase, PhysiologicalPhase.recovering);
  });

  test('a rising trend without a recent low is not recovering', () {
    final phase = PhysiologicalStateEngine.classify(
      _evidence(estimatedNow: 90, velocity: 1.0),
      const [],
    );

    expect(phase, isNot(PhysiologicalPhase.recovering));
  });

  test('classifies absorbingCarbs for a rising trend with active carbs', () {
    final phase = PhysiologicalStateEngine.classify(
      _evidence(estimatedNow: 130, velocity: 1.0, hasActiveCarbs: true),
      const [],
    );

    expect(phase, PhysiologicalPhase.absorbingCarbs);
  });

  test('classifies insulinDominant for a falling trend with an active bolus', () {
    final phase = PhysiologicalStateEngine.classify(
      _evidence(estimatedNow: 130, velocity: -0.8, hasActiveBolus: true),
      const [],
    );

    expect(phase, PhysiologicalPhase.insulinDominant);
  });

  test('classifies stabilizing for a flat trend with no active drivers', () {
    final phase = PhysiologicalStateEngine.classify(
      _evidence(estimatedNow: 100, velocity: 0.1),
      const [],
    );

    expect(phase, PhysiologicalPhase.stabilizing);
  });
}
