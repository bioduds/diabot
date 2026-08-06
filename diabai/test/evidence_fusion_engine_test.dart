import 'package:diabai/cgm/glucose_estimator.dart';
import 'package:diabai/engines/evidence_fusion_engine.dart';
import 'package:diabai/events.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTemporalContext implements TemporalContext {
  const _FakeTemporalContext({
    this.timeSinceMeal,
    this.timeSinceBolus,
    this.timeSinceBasal,
    this.timeSinceExercise,
    this.intenseExercise = false,
  });

  @override
  final Duration? timeSinceMeal;
  @override
  final Duration? timeSinceBolus;
  @override
  final Duration? timeSinceBasal;
  @override
  final Duration? timeSinceExercise;
  @override
  Duration? get timeSinceSymptoms => null;
  final bool intenseExercise;

  @override
  int count(EventType type, Duration within) => 0;

  @override
  bool has(EventType type, Duration within) => false;

  @override
  bool hasFieldValue(
    EventType type,
    String field,
    Object value,
    Duration within,
  ) =>
      type == EventType.exercise && field == 'intensity' && value == 'intensa'
          ? intenseExercise
          : false;
}

GlucoseEstimate _estimate({
  double observed = 100,
  double velocity = 0,
  double residual = 0,
  double confidence = 0.95,
}) =>
    GlucoseEstimate(
      observed: observed,
      estimated: observed,
      estimatedNow: observed,
      velocity: velocity,
      confidence: confidence,
      sigma: 3,
      lagMinutes: 10,
      residual: residual,
    );

void main() {
  test('fuse organizes the glucose estimate without a temporal context', () {
    final evidence = EvidenceFusionEngine.fuse(
      estimate: _estimate(observed: 88, velocity: -1.2, residual: -4),
      at: DateTime.utc(2026, 8, 3, 12),
      stack: const [],
    );

    expect(evidence.referenceTime, DateTime.utc(2026, 8, 3, 12));
    expect(evidence.glucoseEvidence.observed, 88);
    expect(evidence.trendEvidence.velocity, -1.2);
    expect(evidence.trendEvidence.direction, 'falling');
    expect(evidence.symptomEvidence.hasHypoSymptoms, isFalse);
    expect(evidence.insulinEvidence.timeSinceBolus, isNull);
    expect(evidence.insulinEvidence.hasActiveBolus, isFalse);
    expect(evidence.mealEvidence.hasActiveCarbs, isFalse);
    expect(evidence.exerciseEvidence.recentIntenseExercise, isFalse);
  });

  test('fuse extracts the reported symptom type from the current stack', () {
    final evidence = EvidenceFusionEngine.fuse(
      estimate: _estimate(),
      at: DateTime.utc(2026, 8, 3),
      stack: [
        EventInstance(
          type: EventType.symptoms,
          data: const {'symptomType': 'hypo'},
          createdAt: DateTime.utc(2026, 8, 3),
        ),
      ],
    );

    expect(evidence.symptomEvidence.hasHypoSymptoms, isTrue);
    expect(evidence.symptomEvidence.hasHyperSymptoms, isFalse);
  });

  test('fuse carries time-since signals and buckets them into active windows', () {
    final evidence = EvidenceFusionEngine.fuse(
      estimate: _estimate(),
      at: DateTime.utc(2026, 8, 3),
      stack: const [],
      temporalContext: const _FakeTemporalContext(
        timeSinceBolus: Duration(hours: 2),
        timeSinceBasal: Duration(hours: 10),
        timeSinceMeal: Duration(hours: 1),
        timeSinceExercise: Duration(minutes: 30),
        intenseExercise: true,
      ),
    );

    expect(evidence.insulinEvidence.hasActiveBolus, isTrue);
    expect(evidence.mealEvidence.hasActiveCarbs, isTrue);
    expect(evidence.exerciseEvidence.recentIntenseExercise, isTrue);
  });

  test('trend direction respects the stable threshold', () {
    expect(const TrendEvidence(velocity: 0.2).direction, 'stable');
    expect(const TrendEvidence(velocity: 0.6).direction, 'rising');
    expect(const TrendEvidence(velocity: -0.6).direction, 'falling');
  });

  test('insulin/meal evidence fall outside their active window once elapsed', () {
    const insulin = InsulinEvidence(timeSinceBolus: Duration(hours: 5));
    const meal = MealEvidence(timeSinceMeal: Duration(hours: 4));

    expect(insulin.hasActiveBolus, isFalse);
    expect(meal.hasActiveCarbs, isFalse);
  });

  test('fuse computes acceleration from an optional previous estimate', () {
    final at = DateTime.utc(2026, 8, 3, 12, 5);
    final previousAt = DateTime.utc(2026, 8, 3, 12);

    final evidence = EvidenceFusionEngine.fuse(
      estimate: _estimate(velocity: 1.0),
      at: at,
      stack: const [],
      previousEstimate: _estimate(velocity: 0.0),
      previousAt: previousAt,
    );

    expect(evidence.trendEvidence.acceleration, closeTo(0.2, 1e-9));
  });

  test('fuse defaults acceleration to zero without a previous estimate', () {
    final evidence = EvidenceFusionEngine.fuse(
      estimate: _estimate(velocity: 1.0),
      at: DateTime.utc(2026, 8, 3),
      stack: const [],
    );

    expect(evidence.trendEvidence.acceleration, 0.0);
  });
}
