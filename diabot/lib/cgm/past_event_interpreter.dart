import '../engines/evidence_fusion_engine.dart';
import '../engines/hypothesis_engine.dart';
import '../engines/sensor_reliability_engine.dart';
import 'glucose_estimator.dart';

/// What kind of real-world event the Past Event Interpreter suspects
/// explains an otherwise-unaccounted-for divergence between the sensor's
/// observed glucose and the Kalman estimator's prediction. This is
/// intentionally *not* [EventType] (see events.dart): a hypothesis is not
/// yet a real event on the FSM's stack, and confirming/correcting one
/// hands off to the existing meal/insulin/exercise guided modules instead
/// of duplicating their logic here \u2014 see docs/fsm/past_event_interpreter.mmd.
enum HypothesisType { meal, insulin, exercise, dawnPhenomenon, stress }

/// Lifecycle of one [EventHypothesis], scoped to this module only \u2014 it is
/// deliberately separate from [EventStatus] (events.dart), which governs
/// the deterministic event stack. A hypothesis never touches that stack
/// until Nuno resolves it into a real event.
enum HypothesisStatus { pending, confirmed, corrected, dismissed }

/// One CGM/manual glucose reading paired with its timestamp \u2014 the minimal
/// shape the interpreter needs from the chart's own point list, kept free
/// of any UI dependency.
class GlucoseSample {
  const GlucoseSample({required this.at, required this.mgdl});

  final DateTime at;
  final double mgdl;
}

/// A meal/insulin/exercise event already logged by the user (or CGM sync),
/// used to suppress hypotheses for divergences that are already explained.
class KnownContextEvent {
  const KnownContextEvent({required this.type, required this.at});

  final HypothesisType type;
  final DateTime at;
}

/// A probabilistic guess, produced by [PastEventInterpreter.analyze], that
/// something happened around [estimatedStart]\u2013[estimatedPeak] which the
/// Kalman estimator did not predict. Purely descriptive: creating one never
/// changes [DiabAIGlobalState] or [EventStatus], never triggers the
/// Emergency/Priority Engines, and never converses with the user \u2014 only
/// the Timeline (presentation) and Nuno (conversation) do that, once the
/// user taps its marker. See docs/fsm/past_event_interpreter.mmd.
class EventHypothesis {
  const EventHypothesis({
    required this.id,
    required this.type,
    required this.estimatedStart,
    required this.estimatedPeak,
    required this.confidence,
    required this.magnitude,
    required this.explanation,
    required this.evidence,
    required this.status,
  });

  /// Stable identifier, derived from [estimatedPeak] so recomputing the
  /// analysis over the same window updates the same row instead of
  /// duplicating it \u2014 see [PastEventInterpreter._idFor].
  final String id;
  final HypothesisType type;
  final DateTime estimatedStart;
  final DateTime estimatedPeak;

  /// 0..1 heuristic confidence that this hypothesis is correct.
  final double confidence;

  /// Signed magnitude (mg/dL) of the residual that triggered this
  /// hypothesis \u2014 positive for an unexplained rise, negative for a fall.
  final double magnitude;

  /// Nuno-ready explanation text (Portuguese), filled with the real
  /// computed time/values \u2014 a fixed template, not LLM-generated, exactly
  /// like the existing glucose-report feature (see main.dart's
  /// `_receiveGlucoseReport`).
  final String explanation;

  /// Raw signals behind this hypothesis (residual, velocity, acceleration,
  /// Kalman confidence, observed/estimated values) \u2014 logged verbatim to
  /// the local knowledge base for future ICR/ISF/COB/IOB/Bayesian use.
  final Map<String, dynamic> evidence;

  final HypothesisStatus status;

  EventHypothesis copyWith({HypothesisType? type, HypothesisStatus? status}) {
    return EventHypothesis(
      id: id,
      type: type ?? this.type,
      estimatedStart: estimatedStart,
      estimatedPeak: estimatedPeak,
      confidence: confidence,
      magnitude: magnitude,
      explanation: explanation,
      evidence: evidence,
      status: status ?? this.status,
    );
  }
}

/// Persists [EventHypothesis] rows (the individual knowledge-base record
/// described in docs/fsm/past_event_interpreter.mmd) independent of any UI
/// \u2014 implemented by [LocalDatabase] (see lib/local_db.dart).
abstract class HypothesisGateway {
  /// Inserts [hypothesis] only if its id doesn't already exist, so
  /// recomputing the analysis over the same window never overwrites a
  /// status the user already resolved (confirmed/corrected/dismissed).
  Future<void> upsertHypothesisIfAbsent(EventHypothesis hypothesis);

  /// Updates an existing hypothesis's status (and, on correction, its
  /// type) \u2014 never touches [EventHypothesis.evidence]/explanation.
  Future<void> updateHypothesisStatus(
    String id, {
    required HypothesisStatus status,
    HypothesisType? type,
  });

  /// Hypotheses whose [EventHypothesis.estimatedPeak] falls in [start]..
  /// [end], oldest first \u2014 what the Timeline renders as chart markers.
  Future<List<EventHypothesis>> hypothesesInWindow(
    DateTime start,
    DateTime end,
  );
}

/// Observes the Kalman estimator's residual stream and interprets
/// statistically significant, unexplained divergences as [EventHypothesis]
/// candidates. This class only observes and interprets \u2014 it never stores,
/// displays, or converses; see [EventHypothesis] and
/// docs/fsm/past_event_interpreter.mmd for the full separation of
/// responsibilities (Interpreter / Timeline / Nuno).
class PastEventInterpreter {
  const PastEventInterpreter({
    this.residualThresholdMgdl = 10,
    this.minConfidence = 0.55,
    this.suppressionWindow = const Duration(minutes: 20),
    this.dedupeWindow = const Duration(minutes: 15),
    this.dawnWindowStartHour = 4,
    this.dawnWindowEndHour = 8,
    this.risingVelocityThreshold = 0.6,
    this.fallingVelocityThreshold = 0.6,
    this.dawnVelocityCeiling = 0.5,
    this.stressAccelerationThreshold = 0.35,
    this.stressVelocityCeiling = 0.4,
  });

  /// Minimum |residual| (mg/dL) to be considered statistically significant
  /// \u2014 comfortably above the estimator's own sensor-noise scale (\u03c3\u22483).
  final double residualThresholdMgdl;

  /// Hypotheses below this confidence are discarded rather than surfaced.
  final double minConfidence;

  /// A known meal/insulin/exercise event within this window of the
  /// residual suppresses a hypothesis (it is already explained).
  final Duration suppressionWindow;

  /// Adjacent hypotheses of the same type within this window are merged,
  /// keeping only the highest-confidence one \u2014 a sustained divergence
  /// otherwise re-triggers on every reading that crosses the threshold.
  final Duration dedupeWindow;

  final int dawnWindowStartHour;
  final int dawnWindowEndHour;

  final double risingVelocityThreshold;
  final double fallingVelocityThreshold;
  final double dawnVelocityCeiling;
  final double stressAccelerationThreshold;
  final double stressVelocityCeiling;

  /// Runs the analysis over parallel [samples]/[estimates] lists (same
  /// length, same order as produced by the chart's own estimate series)
  /// plus any [knownEvents] already logged, and returns the resulting
  /// hypotheses, deduplicated and sorted by [EventHypothesis.estimatedPeak].
  ///
  /// Classification itself is delegated to [HypothesisEngine], the single
  /// hypothesis generator shared with real-time Nuno reasoning (see
  /// docs/fsm/hypothesis_engine.mmd) \u2014 this class keeps only what is
  /// specific to the Timeline: windowing, known-event suppression,
  /// dedupe, and mapping onto [EventHypothesis].
  List<EventHypothesis> analyze({
    required List<GlucoseSample> samples,
    required List<GlucoseEstimate> estimates,
    List<KnownContextEvent> knownEvents = const [],
  }) {
    assert(samples.length == estimates.length);
    final raw = <EventHypothesis>[];
    final config = HypothesisEngineConfig(
      residualThresholdMgdl: residualThresholdMgdl,
      dawnWindowStartHour: dawnWindowStartHour,
      dawnWindowEndHour: dawnWindowEndHour,
      risingVelocityThreshold: risingVelocityThreshold,
      fallingVelocityThreshold: fallingVelocityThreshold,
      dawnVelocityCeiling: dawnVelocityCeiling,
      stressAccelerationThreshold: stressAccelerationThreshold,
      stressVelocityCeiling: stressVelocityCeiling,
    );

    for (var i = 1; i < samples.length; i++) {
      final residual = estimates[i].residual;
      if (residual.abs() < residualThresholdMgdl) continue;

      final at = samples[i].at;
      if (_explainedByKnownEvent(at, knownEvents)) continue;

      final velocity = estimates[i].velocity;
      final previousVelocity = estimates[i - 1].velocity;
      final dtMinutes =
          samples[i].at.difference(samples[i - 1].at).inSeconds / 60.0;
      final acceleration =
          dtMinutes > 0 ? (velocity - previousVelocity) / dtMinutes : 0.0;
      // Exercise is only ever a reclassification of a fall, mirroring the
      // suppression window's own scale \u2014 see [_explainedByKnownEvent].
      final recentExercise = knownEvents.any((event) =>
          event.type == HypothesisType.exercise &&
          at.difference(event.at).abs() <= suppressionWindow * 3);

      final evidence = EvidenceSet(
        referenceTime: at,
        glucoseEvidence: GlucoseEvidence(
          observed: samples[i].mgdl,
          estimatedNow: estimates[i].estimatedNow,
          residual: residual,
          kalmanConfidence: estimates[i].confidence,
        ),
        trendEvidence: TrendEvidence(
          velocity: velocity,
          acceleration: acceleration,
        ),
        symptomEvidence: const SymptomEvidence(),
        insulinEvidence: const InsulinEvidence(),
        exerciseEvidence: ExerciseEvidence(
          recentIntenseExercise: recentExercise,
        ),
        mealEvidence: const MealEvidence(),
      );
      final reliability = SensorReliabilityEngine.assess(evidence);
      final hypotheses =
          HypothesisEngine.generate(evidence, reliability, config: config);
      final attribution = _firstAttribution(hypotheses);
      if (attribution == null) continue;
      if (attribution.confidence < minConfidence) continue;

      final type = _toHypothesisType(attribution.type);
      raw.add(EventHypothesis(
        id: _idFor(at),
        type: type,
        estimatedStart: at.subtract(const Duration(minutes: 5)),
        estimatedPeak: at,
        confidence: attribution.confidence,
        magnitude: residual,
        explanation: _explanationFor(type, at, residual),
        evidence: {
          'residual': residual,
          'velocity': velocity,
          'acceleration': acceleration,
          'kalmanConfidence': estimates[i].confidence,
          'observed': samples[i].mgdl,
          'estimated': estimates[i].estimated,
        },
        status: HypothesisStatus.pending,
      ));
    }

    return _dedupe(raw);
  }

  bool _explainedByKnownEvent(DateTime at, List<KnownContextEvent> events) {
    for (final event in events) {
      // Exercise never blanket-suppresses a fall — it's reclassified as
      // exercise by [HypothesisEngine] instead, since the user may still
      // want to see/confirm it on the timeline.
      if (event.type == HypothesisType.exercise) continue;
      if (at.difference(event.at).abs() <= suppressionWindow) return true;
    }
    return false;
  }

  static const _attributionTypes = {
    ClinicalHypothesisType.meal,
    ClinicalHypothesisType.insulin,
    ClinicalHypothesisType.exercise,
    ClinicalHypothesisType.dawnPhenomenon,
    ClinicalHypothesisType.stress,
  };

  ClinicalHypothesis? _firstAttribution(List<ClinicalHypothesis> hypotheses) {
    for (final hypothesis in hypotheses) {
      if (_attributionTypes.contains(hypothesis.type)) return hypothesis;
    }
    return null;
  }

  HypothesisType _toHypothesisType(ClinicalHypothesisType type) {
    switch (type) {
      case ClinicalHypothesisType.meal:
        return HypothesisType.meal;
      case ClinicalHypothesisType.insulin:
        return HypothesisType.insulin;
      case ClinicalHypothesisType.exercise:
        return HypothesisType.exercise;
      case ClinicalHypothesisType.dawnPhenomenon:
        return HypothesisType.dawnPhenomenon;
      case ClinicalHypothesisType.stress:
        return HypothesisType.stress;
      default:
        throw StateError('$type is not an attribution hypothesis');
    }
  }

  String _idFor(DateTime at) {
    const bucketMs = 5 * 60 * 1000;
    final bucket = at.millisecondsSinceEpoch ~/ bucketMs;
    return 'hyp_$bucket';
  }

  String _explanationFor(HypothesisType type, DateTime at, double residual) {
    final time = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    switch (type) {
      case HypothesisType.meal:
        return 'Observei uma subida rápida por volta das $time, maior do '
            'que o esperado. Pode ter sido uma refeição.';
      case HypothesisType.insulin:
        return 'Observei uma queda rápida por volta das $time, maior do '
            'que o esperado. Pode ter sido insulina agindo.';
      case HypothesisType.exercise:
        return 'Observei uma queda por volta das $time, coincidindo com um '
            'exercício recente. Pode ter sido esforço físico.';
      case HypothesisType.dawnPhenomenon:
        return 'Observei uma subida gradual durante a madrugada, por volta '
            'das $time. Pode ser o fenômeno do amanhecer.';
      case HypothesisType.stress:
        return 'Observei uma variação irregular por volta das $time, sem '
            'uma causa clara nos registros. Pode ter sido estresse.';
    }
  }

  List<EventHypothesis> _dedupe(List<EventHypothesis> hypotheses) {
    final sorted = [...hypotheses]
      ..sort((a, b) => a.estimatedPeak.compareTo(b.estimatedPeak));
    final result = <EventHypothesis>[];
    for (final hypothesis in sorted) {
      final clusterIndex = result.lastIndexWhere((existing) =>
          existing.type == hypothesis.type &&
          hypothesis.estimatedPeak
                  .difference(existing.estimatedPeak)
                  .abs() <=
              dedupeWindow);
      if (clusterIndex == -1) {
        result.add(hypothesis);
        continue;
      }
      if (hypothesis.confidence > result[clusterIndex].confidence) {
        result[clusterIndex] = hypothesis;
      }
    }
    return result;
  }
}
