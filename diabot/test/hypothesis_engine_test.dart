import 'package:diabai/engines/evidence_fusion_engine.dart';
import 'package:diabai/engines/hypothesis_engine.dart';
import 'package:diabai/engines/sensor_reliability_engine.dart';
import 'package:flutter_test/flutter_test.dart';

EvidenceSet _evidence({
  DateTime? at,
  double observed = 100,
  double estimatedNow = 100,
  double residual = 0,
  double velocity = 0,
  double acceleration = 0,
  double kalmanConfidence = 0.95,
  bool hasHypoSymptoms = false,
  bool recentIntenseExercise = false,
}) =>
    EvidenceSet(
      referenceTime: at ?? DateTime.utc(2026, 8, 3, 12),
      glucoseEvidence: GlucoseEvidence(
        observed: observed,
        estimatedNow: estimatedNow,
        residual: residual,
        kalmanConfidence: kalmanConfidence,
      ),
      trendEvidence: TrendEvidence(
        velocity: velocity,
        acceleration: acceleration,
      ),
      symptomEvidence: SymptomEvidence(hasHypoSymptoms: hasHypoSymptoms),
      insulinEvidence: const InsulinEvidence(),
      exerciseEvidence: ExerciseEvidence(
        recentIntenseExercise: recentIntenseExercise,
      ),
      mealEvidence: const MealEvidence(),
    );

const _reliable = SensorReliability(
  confidence: 0.95,
  probableLag: false,
  probableCompression: false,
  probableSensorError: false,
);

void main() {
  group('HypothesisEngine state hypotheses', () {
    test('flags true hypoglycemia when the sensor is trustworthy', () {
      final hypotheses = HypothesisEngine.generate(
        _evidence(estimatedNow: 60, kalmanConfidence: 0.95),
        _reliable,
      );

      expect(
        hypotheses.first.type,
        ClinicalHypothesisType.trueHypoglycemia,
      );
      expect(hypotheses.first.confidence, 0.95);
    });

    test('flags true hyperglycemia when the sensor is trustworthy', () {
      const trustworthy = SensorReliability(
        confidence: 0.9,
        probableLag: false,
        probableCompression: false,
        probableSensorError: false,
      );

      final hypotheses = HypothesisEngine.generate(
        _evidence(estimatedNow: 220),
        trustworthy,
      );

      expect(
        hypotheses.first.type,
        ClinicalHypothesisType.trueHyperglycemia,
      );
      expect(hypotheses.first.confidence, 0.9);
    });

    test('discounts a true-hypoglycemia reading when the sensor is unreliable', () {
      const unreliable = SensorReliability(
        confidence: 0.8,
        probableLag: true,
        probableCompression: false,
        probableSensorError: false,
      );

      final hypotheses = HypothesisEngine.generate(
        _evidence(
          estimatedNow: 60,
          residual: 20,
          velocity: -3,
          kalmanConfidence: 0.8,
        ),
        unreliable,
      );

      final hypo = hypotheses.firstWhere(
        (h) => h.type == ClinicalHypothesisType.trueHypoglycemia,
      );
      expect(hypo.confidence, closeTo(0.4, 1e-9));
    });

    test('surfaces sensorLag ahead of a discounted true-state hypothesis', () {
      const lagged = SensorReliability(
        confidence: 0.4,
        probableLag: true,
        probableCompression: false,
        probableSensorError: false,
      );

      final hypotheses = HypothesisEngine.generate(
        _evidence(
          estimatedNow: 60,
          residual: 20,
          velocity: -3,
          kalmanConfidence: 0.4,
        ),
        lagged,
      );

      expect(hypotheses.first.type, ClinicalHypothesisType.sensorLag);
    });

    test('surfaces sensorError from very low reliability confidence', () {
      const errorProne = SensorReliability(
        confidence: 0.2,
        probableLag: false,
        probableCompression: false,
        probableSensorError: true,
      );

      final hypotheses = HypothesisEngine.generate(
        _evidence(estimatedNow: 100),
        errorProne,
      );

      expect(hypotheses.first.type, ClinicalHypothesisType.sensorError);
      expect(hypotheses.first.confidence, closeTo(0.8, 1e-9));
    });

    test('produces no state hypothesis for glucose within normal range', () {
      final hypotheses = HypothesisEngine.generate(
        _evidence(estimatedNow: 100),
        _reliable,
      );

      expect(
        hypotheses.where((h) =>
            h.type == ClinicalHypothesisType.trueHypoglycemia ||
            h.type == ClinicalHypothesisType.trueHyperglycemia),
        isEmpty,
      );
    });
  });

  group('HypothesisEngine attribution hypotheses', () {
    test('classifies a rising, above-threshold residual as meal', () {
      final hypotheses = HypothesisEngine.generate(
        _evidence(residual: 15, velocity: 1.0),
        _reliable,
      );

      expect(hypotheses.first.type, ClinicalHypothesisType.meal);
    });

    test('classifies a falling, above-threshold residual as insulin', () {
      final hypotheses = HypothesisEngine.generate(
        _evidence(residual: -15, velocity: -1.0),
        _reliable,
      );

      expect(hypotheses.first.type, ClinicalHypothesisType.insulin);
    });

    test('reclassifies a fall as exercise when recent exercise is reported', () {
      final hypotheses = HypothesisEngine.generate(
        _evidence(residual: -15, velocity: -1.0, recentIntenseExercise: true),
        _reliable,
      );

      expect(hypotheses.first.type, ClinicalHypothesisType.exercise);
    });

    test('classifies a slow overnight rise in the dawn window as dawnPhenomenon', () {
      final hypotheses = HypothesisEngine.generate(
        _evidence(
          at: DateTime.utc(2026, 8, 3, 5, 30),
          residual: 12,
          velocity: 0.3,
        ),
        _reliable,
      );

      expect(hypotheses.first.type, ClinicalHypothesisType.dawnPhenomenon);
    });

    test('classifies a sharp acceleration with low velocity as stress', () {
      final hypotheses = HypothesisEngine.generate(
        _evidence(residual: 12, velocity: 0.1, acceleration: 0.5),
        _reliable,
      );

      expect(hypotheses.first.type, ClinicalHypothesisType.stress);
    });

    test('produces no attribution hypothesis below the residual threshold', () {
      final hypotheses = HypothesisEngine.generate(
        _evidence(residual: 5, velocity: 1.0),
        _reliable,
      );

      expect(
        hypotheses.where((h) => h.type == ClinicalHypothesisType.meal),
        isEmpty,
      );
    });

    test('produces no attribution hypothesis when no branch matches', () {
      final hypotheses = HypothesisEngine.generate(
        _evidence(residual: 12, velocity: 0.1, acceleration: 0.1),
        _reliable,
      );

      final attributionTypes = {
        ClinicalHypothesisType.meal,
        ClinicalHypothesisType.insulin,
        ClinicalHypothesisType.exercise,
        ClinicalHypothesisType.dawnPhenomenon,
        ClinicalHypothesisType.stress,
      };
      expect(
        hypotheses.where((h) => attributionTypes.contains(h.type)),
        isEmpty,
      );
    });
  });

  test('generate ranks hypotheses by descending confidence', () {
    final hypotheses = HypothesisEngine.generate(
      _evidence(estimatedNow: 60, residual: -15, velocity: -1.0),
      _reliable,
    );

    expect(hypotheses.length, greaterThan(1));
    for (var i = 1; i < hypotheses.length; i++) {
      expect(
        hypotheses[i - 1].confidence,
        greaterThanOrEqualTo(hypotheses[i].confidence),
      );
    }
  });

  test('residualConfidence matches the original PastEventInterpreter formula', () {
    // 1 - exp(-|residual| / (threshold * 1.5)), clamped to 0.99.
    final confidence = HypothesisEngine.residualConfidence(15);
    expect(confidence, closeTo(1 - 0.36787944117 /* e^-1 */, 1e-6));
  });
}
