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
    required this.effectWindowEnd,
    required this.confidence,
    required this.magnitude,
    required this.explanation,
    required this.evidence,
    required this.status,
    this.linkedEventId,
  });

  /// Stable identifier, derived from the *first* reading that started
  /// this hypothesis thread (see [PastEventInterpreter._mergeCluster]), so
  /// recomputing the analysis over a growing window keeps updating the
  /// same row \u2014 confidence rising or new evidence arriving never spawns
  /// a duplicate \u2014 instead of creating a new one every time a later,
  /// more-confident reading of the same ongoing phenomenon is observed.
  /// See [PastEventInterpreter._idFor].
  final String id;
  final HypothesisType type;

  /// CauseTime: when the underlying physiological cause (meal, insulin,
  /// exercise, ...) most likely began, pushed back from [estimatedPeak]
  /// by [PastEventInterpreter._causeLatencyFor] — always at or before
  /// [estimatedPeak], never after.
  final DateTime estimatedStart;

  /// DetectionTime: the exact reading whose residual first crossed the
  /// significance threshold and produced this hypothesis (or, once
  /// merged into a thread, the most recent such reading — see
  /// [PastEventInterpreter._mergeCluster]).
  final DateTime estimatedPeak;

  /// EffectWindow end: how long after [estimatedPeak] this cause type's
  /// physiological effect can still plausibly explain new divergence,
  /// from [PastEventInterpreter._effectDurationFor]. New evidence of the
  /// same type arriving at or before this time is threaded into this
  /// same hypothesis (see [PastEventInterpreter._dedupe]) instead of
  /// starting a new one; evidence arriving after it starts a fresh
  /// episode, since the original cause can no longer explain it.
  final DateTime effectWindowEnd;

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

  /// [EventInstance.id] of the meal/insulin/exercise event this hypothesis
  /// resolved to once the user confirmed/corrected it (see main.dart's
  /// `_hypothesisAwaitingEventLink`) — null until then, and always null for
  /// dawnPhenomenon/stress, which never create a linked event. Lets
  /// re-tapping an already-resolved marker describe the real stored data
  /// instead of asking Sim/Corrigir/Ignorar again.
  final String? linkedEventId;

  EventHypothesis copyWith({HypothesisType? type, HypothesisStatus? status}) {
    return EventHypothesis(
      id: id,
      type: type ?? this.type,
      estimatedStart: estimatedStart,
      estimatedPeak: estimatedPeak,
      effectWindowEnd: effectWindowEnd,
      confidence: confidence,
      magnitude: magnitude,
      explanation: explanation,
      evidence: evidence,
      status: status ?? this.status,
      linkedEventId: linkedEventId,
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

  /// Updates the stored row matching [hypothesis].id's evidence/confidence
  /// /peak/explanation in place, but only while it is still
  /// [HypothesisStatus.pending] — this is how an ongoing hypothesis
  /// thread (see [PastEventInterpreter._dedupe]) keeps evolving across
  /// repeated analysis runs without ever touching a row the user already
  /// confirmed/corrected/dismissed. Returns true if a pending row was
  /// found and updated, false otherwise (including "id not found yet",
  /// which callers should treat as "insert it instead").
  Future<bool> refreshPendingHypothesis(EventHypothesis hypothesis);

  /// Updates an existing hypothesis's status (and, on correction, its
  /// type) \u2014 never touches [EventHypothesis.evidence]/explanation.
  Future<void> updateHypothesisStatus(
    String id, {
    required HypothesisStatus status,
    HypothesisType? type,
  });

  /// Records which stored event a resolved hypothesis turned into, once
  /// that event actually finishes being logged (may be several turns after
  /// [updateHypothesisStatus] set its status — see main.dart's
  /// `_hypothesisAwaitingEventLink`).
  Future<void> linkHypothesisToEvent(String id, String eventId);

  // Realigns a resolved hypothesis's own estimatedStart/effectWindowEnd to
  // the time the user actually confirmed via the curve time picker (which
  // may differ from the original detection-time-derived guess) — see
  // main.dart's post-correction linking, request #1 (glucose_time_picker's
  // drag-on-the-curve dialog). effectWindowEnd shifts by the same delta so
  // its own duration is preserved.
  Future<void> realignHypothesisTiming(String id, DateTime estimatedStart);

  /// Hypotheses whose [EventHypothesis.estimatedPeak] falls in [start]..
  /// [end], oldest first \u2014 what the Timeline renders as chart markers.
  Future<List<EventHypothesis>> hypothesesInWindow(
    DateTime start,
    DateTime end,
  );

  /// Deletes any other still-[HypothesisStatus.pending] row of the same
  /// type whose estimatedPeak falls inside [merged]'s own causal span —
  /// cleans up stale duplicate rows left behind by candidates that
  /// [PastEventInterpreter._dedupe] now folds into this single thread, so
  /// every hypothesis type merges the same way (not just meal).
  Future<void> prunePendingDuplicates(EventHypothesis merged);
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

  final int dawnWindowStartHour;
  final int dawnWindowEndHour;

  final double risingVelocityThreshold;
  final double fallingVelocityThreshold;
  final double dawnVelocityCeiling;
  final double stressAccelerationThreshold;
  final double stressVelocityCeiling;

  /// How long before detection this cause type's effect is typically
  /// still latent/invisible — used to push [EventHypothesis.estimatedStart]
  /// (CauseTime) back from the reading that actually crossed the residual
  /// threshold (DetectionTime). Heuristic magnitudes only, not a dosing or
  /// clinical parameter: meal/insulin onset takes a few minutes to show up
  /// in interstitial glucose; exercise and stress are visible almost
  /// immediately; dawn phenomenon has no discrete external cause to place
  /// earlier than its own gradual onset.
  Duration _causeLatencyFor(HypothesisType type) {
    switch (type) {
      case HypothesisType.meal:
      case HypothesisType.insulin:
        return const Duration(minutes: 15);
      case HypothesisType.exercise:
      case HypothesisType.stress:
        return const Duration(minutes: 5);
      case HypothesisType.dawnPhenomenon:
        return Duration.zero;
    }
  }

  /// How long this cause type's physiological effect can still plausibly
  /// explain new divergence after a reading that reinforced it — the
  /// EffectWindow used by [_dedupe] to thread later evidence into the same
  /// hypothesis instead of starting a new one (see [_mergeCluster]).
  /// Heuristic magnitudes only: roughly the typical postprandial glucose
  /// excursion for a meal, the app's own rapid-acting insulin action
  /// duration default for insulin, a couple of hours for exercise
  /// (including delayed effects), the dawn window's own span for dawn
  /// phenomenon, and a shorter, less-defined window for stress.
  Duration _effectDurationFor(HypothesisType type) {
    switch (type) {
      case HypothesisType.meal:
        return const Duration(minutes: 180);
      case HypothesisType.insulin:
        return const Duration(minutes: 240);
      case HypothesisType.exercise:
        return const Duration(minutes: 120);
      case HypothesisType.dawnPhenomenon:
        return Duration(hours: dawnWindowEndHour - dawnWindowStartHour);
      case HypothesisType.stress:
        return const Duration(minutes: 90);
    }
  }

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
      final estimatedStart = at.subtract(_causeLatencyFor(type));
      raw.add(EventHypothesis(
        id: _idFor(at),
        type: type,
        estimatedStart: estimatedStart,
        estimatedPeak: at,
        effectWindowEnd: at.add(_effectDurationFor(type)),
        confidence: attribution.confidence,
        magnitude: residual,
        explanation: _explanationFor(type, estimatedStart),
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

  /// Succinct, single-line phrasing per request #3 — names only the
  /// probable start (CauseTime, [EventHypothesis.estimatedStart]) instead
  /// of the detection time, and asks the type as a short question instead
  /// of narrating the raw signal ("Ainda observo..."); an ongoing thread
  /// (see [_mergeCluster]) reuses this same template unchanged, since the
  /// CauseTime it names never moves once a thread starts.
  String _explanationFor(HypothesisType type, DateTime start) {
    final time = _formatTime(start);
    switch (type) {
      case HypothesisType.meal:
        return '$time: Início de subida rápida de glicemia. Refeição?';
      case HypothesisType.insulin:
        return '$time: Início de queda rápida de glicemia. Insulina?';
      case HypothesisType.exercise:
        return '$time: Início de queda de glicemia, coincidindo com '
            'exercício recente. Exercício?';
      case HypothesisType.dawnPhenomenon:
        return '$time: Início de subida gradual de glicemia. Fenômeno do '
            'amanhecer?';
      case HypothesisType.stress:
        return '$time: Início de variação irregular de glicemia. Estresse?';
    }
  }

  String _formatTime(DateTime at) {
    return '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
  }

  /// Threads each candidate into the most recent same-type cluster whose
  /// EffectWindow ([EventHypothesis.effectWindowEnd]) it still falls
  /// within, instead of matching against a single confidence-weighted
  /// "winner" or a flat time window \u2014 this is what lets a slow, sustained
  /// divergence (see the module doc comment) be tracked as one hypothesis
  /// whose confidence/duration/effect window evolve, rather than
  /// restarting the window every time a higher- or lower-confidence
  /// reading arrives, or splitting a still-explained meal/insulin episode
  /// just because two readings happen to be more than a few minutes apart.
  List<EventHypothesis> _dedupe(List<EventHypothesis> hypotheses) {
    final sorted = [...hypotheses]
      ..sort((a, b) => a.estimatedPeak.compareTo(b.estimatedPeak));
    final clusters = <List<EventHypothesis>>[];
    for (final hypothesis in sorted) {
      final clusterIndex = clusters.lastIndexWhere((cluster) =>
          cluster.last.type == hypothesis.type &&
          !hypothesis.estimatedPeak.isAfter(cluster.last.effectWindowEnd));
      if (clusterIndex == -1) {
        clusters.add([hypothesis]);
      } else {
        clusters[clusterIndex].add(hypothesis);
      }
    }
    return [for (final cluster in clusters) _mergeCluster(cluster)];
  }

  /// Collapses one thread of same-type, temporally-continuous candidates
  /// into a single [EventHypothesis] that keeps the *first* candidate's
  /// id/[EventHypothesis.estimatedStart] (so its identity — and therefore
  /// its stored row — never changes across repeated analysis runs, see
  /// [PastEventInterpreter.analyze]'s doc comment and
  /// `HypothesisGateway.refreshPendingHypothesis`), the *last* candidate's
  /// estimatedPeak/effectWindowEnd/magnitude/evidence (the most recent
  /// observation of the same phenomenon, and how much further it still
  /// extends the episode's EffectWindow), and the highest confidence
  /// observed so far.
  EventHypothesis _mergeCluster(List<EventHypothesis> cluster) {
    if (cluster.length == 1) return cluster.single;
    final first = cluster.first;
    final last = cluster.last;
    var peakConfidence = first.confidence;
    for (final hypothesis in cluster) {
      if (hypothesis.confidence > peakConfidence) {
        peakConfidence = hypothesis.confidence;
      }
    }
    return EventHypothesis(
      id: first.id,
      type: last.type,
      estimatedStart: first.estimatedStart,
      estimatedPeak: last.estimatedPeak,
      effectWindowEnd: last.effectWindowEnd,
      confidence: peakConfidence,
      magnitude: last.magnitude,
      explanation: _explanationFor(last.type, first.estimatedStart),
      evidence: {
        ...last.evidence,
        'firstObservedAt': first.estimatedStart.toIso8601String(),
        'observationCount': cluster.length,
      },
      status: HypothesisStatus.pending,
    );
  }
}

