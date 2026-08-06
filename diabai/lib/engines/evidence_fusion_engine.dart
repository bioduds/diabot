import '../cgm/glucose_estimator.dart';
import '../events.dart';

/// The Kalman filter's own read of the current reading — never a judgment,
/// see lib/cgm/glucose_estimator.dart.
class GlucoseEvidence {
  const GlucoseEvidence({
    required this.observed,
    required this.estimatedNow,
    required this.residual,
    required this.kalmanConfidence,
  });

  final double observed;
  final double estimatedNow;
  final double residual;
  final double kalmanConfidence;
}

/// Rate of change only — direction is a plain threshold label, not a claim
/// about cause. [acceleration] is the change in velocity per minute, 0 when
/// there is no prior reading to compare against.
class TrendEvidence {
  const TrendEvidence({required this.velocity, this.acceleration = 0.0});

  final double velocity;
  final double acceleration;

  static const stableThreshold = 0.5;

  String get direction {
    if (velocity > stableThreshold) return 'rising';
    if (velocity < -stableThreshold) return 'falling';
    return 'stable';
  }
}

/// Symptom types reported this turn, per lib/events.dart's canonical
/// 'hypo'/'hyper' values.
class SymptomEvidence {
  const SymptomEvidence({
    this.hasHypoSymptoms = false,
    this.hasHyperSymptoms = false,
  });

  final bool hasHypoSymptoms;
  final bool hasHyperSymptoms;
}

/// v1 IOB proxy: elapsed time since the last dose, not a pharmacokinetic
/// decay curve — see Further Considerations #1 in the V2 plan.
class InsulinEvidence {
  const InsulinEvidence({this.timeSinceBolus, this.timeSinceBasal});

  final Duration? timeSinceBolus;
  final Duration? timeSinceBasal;

  static const activeWindow = Duration(hours: 4);

  bool get hasActiveBolus =>
      timeSinceBolus != null && timeSinceBolus! <= activeWindow;
}

class ExerciseEvidence {
  const ExerciseEvidence({
    this.timeSinceExercise,
    this.recentIntenseExercise = false,
  });

  final Duration? timeSinceExercise;
  final bool recentIntenseExercise;
}

/// v1 COB proxy: elapsed time since the last meal, not a carb-absorption
/// curve — see Further Considerations #1 in the V2 plan.
class MealEvidence {
  const MealEvidence({this.timeSinceMeal});

  final Duration? timeSinceMeal;

  static const activeWindow = Duration(hours: 3);

  bool get hasActiveCarbs =>
      timeSinceMeal != null && timeSinceMeal! <= activeWindow;
}

/// One turn's fused signals — organized only, no probability or judgment.
/// Consumed by SensorReliabilityEngine and HypothesisEngine.
class EvidenceSet {
  const EvidenceSet({
    required this.referenceTime,
    required this.glucoseEvidence,
    required this.trendEvidence,
    required this.symptomEvidence,
    required this.insulinEvidence,
    required this.exerciseEvidence,
    required this.mealEvidence,
  });

  /// When this evidence was assembled — the current turn's time, or a
  /// historical sample's timestamp when built by PastEventInterpreter.
  /// Needed for time-of-day reasoning (e.g. dawn phenomenon).
  final DateTime referenceTime;
  final GlucoseEvidence glucoseEvidence;
  final TrendEvidence trendEvidence;
  final SymptomEvidence symptomEvidence;
  final InsulinEvidence insulinEvidence;
  final ExerciseEvidence exerciseEvidence;
  final MealEvidence mealEvidence;
}

/// See docs/fsm/evidence_fusion_engine.mmd. Combines the Kalman estimate,
/// TimeEngine's temporal context, and the current turn's reported symptoms
/// into one [EvidenceSet]. Computes no probabilities or decisions itself.
class EvidenceFusionEngine {
  const EvidenceFusionEngine._();

  static const intenseExerciseWindow = Duration(hours: 2);

  static EvidenceSet fuse({
    required GlucoseEstimate estimate,
    required DateTime at,
    required List<EventInstance> stack,
    TemporalContext? temporalContext,
    GlucoseEstimate? previousEstimate,
    DateTime? previousAt,
  }) {
    String? symptomType;
    for (final event in stack) {
      if (event.type == EventType.symptoms &&
          event.data['symptomType'] != null) {
        symptomType ??= event.data['symptomType'] as String;
      }
    }

    var acceleration = 0.0;
    if (previousEstimate != null && previousAt != null) {
      final dtMinutes = at.difference(previousAt).inSeconds / 60.0;
      if (dtMinutes > 0) {
        acceleration =
            (estimate.velocity - previousEstimate.velocity) / dtMinutes;
      }
    }

    return EvidenceSet(
      referenceTime: at,
      glucoseEvidence: GlucoseEvidence(
        observed: estimate.observed,
        estimatedNow: estimate.estimatedNow,
        residual: estimate.residual,
        kalmanConfidence: estimate.confidence,
      ),
      trendEvidence: TrendEvidence(
        velocity: estimate.velocity,
        acceleration: acceleration,
      ),
      symptomEvidence: SymptomEvidence(
        hasHypoSymptoms: symptomType == 'hypo',
        hasHyperSymptoms: symptomType == 'hyper',
      ),
      insulinEvidence: InsulinEvidence(
        timeSinceBolus: temporalContext?.timeSinceBolus,
        timeSinceBasal: temporalContext?.timeSinceBasal,
      ),
      exerciseEvidence: ExerciseEvidence(
        timeSinceExercise: temporalContext?.timeSinceExercise,
        recentIntenseExercise: temporalContext?.hasFieldValue(
              EventType.exercise,
              'intensity',
              'intensa',
              intenseExerciseWindow,
            ) ??
            false,
      ),
      mealEvidence: MealEvidence(
        timeSinceMeal: temporalContext?.timeSinceMeal,
      ),
    );
  }
}
