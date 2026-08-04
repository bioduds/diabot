import 'package:diabai/engines/evidence_fusion_engine.dart';
import 'package:diabai/engines/sensor_reliability_engine.dart';
import 'package:flutter_test/flutter_test.dart';

EvidenceSet _evidence({
  double residual = 0,
  double velocity = 0,
  double confidence = 0.95,
  bool hasHypoSymptoms = false,
}) =>
    EvidenceSet(
      referenceTime: DateTime.utc(2026, 8, 3, 12),
      glucoseEvidence: GlucoseEvidence(
        observed: 100,
        estimatedNow: 100,
        residual: residual,
        kalmanConfidence: confidence,
      ),
      trendEvidence: TrendEvidence(velocity: velocity),
      symptomEvidence: SymptomEvidence(hasHypoSymptoms: hasHypoSymptoms),
      insulinEvidence: const InsulinEvidence(),
      exerciseEvidence: const ExerciseEvidence(),
      mealEvidence: const MealEvidence(),
    );

void main() {
  test('assess reports no reliability concerns for a clean, stable reading', () {
    final reliability = SensorReliabilityEngine.assess(
      _evidence(residual: 1, velocity: 0.1, confidence: 0.95),
    );

    expect(reliability.confidence, 0.95);
    expect(reliability.probableLag, isFalse);
    expect(reliability.probableCompression, isFalse);
    expect(reliability.probableSensorError, isFalse);
  });

  test('assess flags probable lag on a fast, low-confidence, large-residual reading', () {
    final reliability = SensorReliabilityEngine.assess(
      _evidence(residual: 20, velocity: -3, confidence: 0.4),
    );

    expect(reliability.probableLag, isTrue);
    expect(reliability.probableCompression, isFalse);
    expect(reliability.probableSensorError, isFalse);
  });

  test('assess flags probable compression on a falling, low-confidence reading without hypo symptoms', () {
    final reliability = SensorReliabilityEngine.assess(
      _evidence(residual: -5, velocity: -1, confidence: 0.4),
    );

    expect(reliability.probableLag, isFalse);
    expect(reliability.probableCompression, isTrue);
  });

  test('falling low-confidence reading with hypo symptoms is not treated as compression', () {
    final reliability = SensorReliabilityEngine.assess(
      _evidence(
        residual: -5,
        velocity: -1,
        confidence: 0.4,
        hasHypoSymptoms: true,
      ),
    );

    expect(reliability.probableCompression, isFalse);
    expect(reliability.probableSensorError, isFalse);
  });

  test('assess falls back to sensor error for very low confidence with no other pattern', () {
    final reliability = SensorReliabilityEngine.assess(
      _evidence(residual: 1, velocity: 0.1, confidence: 0.2),
    );

    expect(reliability.probableLag, isFalse);
    expect(reliability.probableCompression, isFalse);
    expect(reliability.probableSensorError, isTrue);
  });
}
