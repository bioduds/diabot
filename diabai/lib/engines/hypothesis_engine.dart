import 'dart:math' as math;

import 'evidence_fusion_engine.dart';
import 'sensor_reliability_engine.dart';

/// The single hypothesis taxonomy in DiabAI \u2014 state hypotheses (what the
/// glucose signal itself might mean) plus attribution hypotheses (what
/// real-world event might explain a divergence). Order matches
/// docs/fsm/hypothesis_engine.mmd's `hypothesisTypes` exactly.
enum ClinicalHypothesisType {
  trueHypoglycemia,
  trueHyperglycemia,
  sensorLag,
  compressionArtifact,
  sensorError,
  meal,
  insulin,
  exercise,
  dawnPhenomenon,
  stress,
}

/// One ranked candidate explanation. Purely descriptive: [rationale] is an
/// internal, English debugging note, not user-facing copy \u2014 ResponseBuilder
/// owns the words Nuno actually says. Generating one never touches
/// DiabAIGlobalState/EventStatus and never talks to the user.
class ClinicalHypothesis {
  const ClinicalHypothesis({
    required this.type,
    required this.confidence,
    required this.rationale,
  });

  final ClinicalHypothesisType type;

  /// 0..1 heuristic confidence that this hypothesis is correct.
  final double confidence;

  final String rationale;
}

/// Thresholds behind [HypothesisEngine.generate], factored out so
/// PastEventInterpreter can keep its own configurable defaults while
/// sharing this engine's classification math instead of duplicating it.
class HypothesisEngineConfig {
  const HypothesisEngineConfig({
    this.residualThresholdMgdl = 10,
    this.hypoglycemiaThresholdMgdl = 70,
    this.hyperglycemiaThresholdMgdl = 180,
    this.dawnWindowStartHour = 4,
    this.dawnWindowEndHour = 8,
    this.risingVelocityThreshold = 0.6,
    this.fallingVelocityThreshold = 0.6,
    this.dawnVelocityCeiling = 0.5,
    this.stressAccelerationThreshold = 0.35,
    this.stressVelocityCeiling = 0.4,
  });

  /// Minimum |residual| (mg/dL) for an attribution hypothesis to be
  /// considered at all \u2014 comfortably above the estimator's own
  /// sensor-noise scale (\u03c3\u22483).
  final double residualThresholdMgdl;

  final double hypoglycemiaThresholdMgdl;
  final double hyperglycemiaThresholdMgdl;

  final int dawnWindowStartHour;
  final int dawnWindowEndHour;

  final double risingVelocityThreshold;
  final double fallingVelocityThreshold;
  final double dawnVelocityCeiling;
  final double stressAccelerationThreshold;
  final double stressVelocityCeiling;
}

/// See docs/fsm/hypothesis_engine.mmd. The single hypothesis generator in
/// DiabAI \u2014 ranks candidate explanations for the current [EvidenceSet] and
/// [SensorReliability], mixing state hypotheses (is this reading itself
/// trustworthy/dangerous?) with attribution hypotheses (what event
/// explains it?). Only ranks; never stores, never converses, never
/// touches the FSM's lifecycle or the Emergency/Priority Engines.
class HypothesisEngine {
  const HypothesisEngine._();

  /// Shared with PastEventInterpreter, which used to compute this itself
  /// before this engine existed \u2014 kept identical to avoid behavior drift.
  static double residualConfidence(
    double residual, {
    double thresholdMgdl = 10,
  }) {
    final scale = thresholdMgdl * 1.5;
    final raw = 1 - math.exp(-residual.abs() / scale);
    return raw.clamp(0.0, 0.99);
  }

  static List<ClinicalHypothesis> generate(
    EvidenceSet evidence,
    SensorReliability reliability, {
    HypothesisEngineConfig config = const HypothesisEngineConfig(),
  }) {
    final hypotheses = <ClinicalHypothesis>[
      ..._stateHypotheses(evidence, reliability, config),
      ..._attributionHypotheses(evidence, config),
    ];
    hypotheses.sort((a, b) => b.confidence.compareTo(a.confidence));
    return hypotheses;
  }

  static List<ClinicalHypothesis> _stateHypotheses(
    EvidenceSet evidence,
    SensorReliability reliability,
    HypothesisEngineConfig config,
  ) {
    final hypotheses = <ClinicalHypothesis>[];
    final glucose = evidence.glucoseEvidence;

    if (reliability.probableSensorError) {
      hypotheses.add(ClinicalHypothesis(
        type: ClinicalHypothesisType.sensorError,
        confidence: 1 - reliability.confidence,
        rationale: 'Kalman confidence '
            '${reliability.confidence.toStringAsFixed(2)} is very low with '
            'no lag or compression pattern matched.',
      ));
    } else if (reliability.probableLag) {
      hypotheses.add(ClinicalHypothesis(
        type: ClinicalHypothesisType.sensorLag,
        confidence: residualConfidence(
          glucose.residual,
          thresholdMgdl: config.residualThresholdMgdl,
        ),
        rationale: 'Fast trend with a large, low-confidence residual '
            'suggests interstitial lag rather than a true reading.',
      ));
    } else if (reliability.probableCompression) {
      hypotheses.add(ClinicalHypothesis(
        type: ClinicalHypothesisType.compressionArtifact,
        confidence: 1 - reliability.confidence,
        rationale: 'Falling, low-confidence reading without hypo symptoms '
            'suggests possible sensor compression.',
      ));
    }

    // Sensor-trust hypotheses above compete with, rather than block, the
    // true-state hypotheses below \u2014 an untrustworthy reading just lowers
    // how much weight the true-state reading deserves.
    final sensorTrusted = !reliability.probableLag &&
        !reliability.probableCompression &&
        !reliability.probableSensorError;
    final stateConfidence =
        sensorTrusted ? reliability.confidence : reliability.confidence * 0.5;

    if (glucose.estimatedNow < config.hypoglycemiaThresholdMgdl) {
      hypotheses.add(ClinicalHypothesis(
        type: ClinicalHypothesisType.trueHypoglycemia,
        confidence: stateConfidence,
        rationale: 'Estimated current glucose '
            '${glucose.estimatedNow.toStringAsFixed(0)} mg/dL is below the '
            'hypoglycemia threshold.',
      ));
    } else if (glucose.estimatedNow > config.hyperglycemiaThresholdMgdl) {
      hypotheses.add(ClinicalHypothesis(
        type: ClinicalHypothesisType.trueHyperglycemia,
        confidence: stateConfidence,
        rationale: 'Estimated current glucose '
            '${glucose.estimatedNow.toStringAsFixed(0)} mg/dL is above the '
            'hyperglycemia threshold.',
      ));
    }

    return hypotheses;
  }

  /// Mirrors PastEventInterpreter's original `_classify`: mutually
  /// exclusive, so at most one attribution hypothesis is ever produced.
  static List<ClinicalHypothesis> _attributionHypotheses(
    EvidenceSet evidence,
    HypothesisEngineConfig config,
  ) {
    final residual = evidence.glucoseEvidence.residual;
    if (residual.abs() < config.residualThresholdMgdl) return const [];

    final velocity = evidence.trendEvidence.velocity;
    final acceleration = evidence.trendEvidence.acceleration;
    final hour = evidence.referenceTime.hour;
    final inDawnWindow =
        hour >= config.dawnWindowStartHour && hour < config.dawnWindowEndHour;

    ClinicalHypothesisType? type;
    // Checked before the meal branch: a slow, sustained overnight rise
    // never crosses risingVelocityThreshold, so it must be classified on
    // its own, lower velocity band rather than as a fallthrough of it.
    if (residual > 0 &&
        inDawnWindow &&
        velocity > 0 &&
        velocity <= config.dawnVelocityCeiling) {
      type = ClinicalHypothesisType.dawnPhenomenon;
    } else if (residual > 0 && velocity > config.risingVelocityThreshold) {
      type = ClinicalHypothesisType.meal;
    } else if (residual < 0 && velocity < -config.fallingVelocityThreshold) {
      type = evidence.exerciseEvidence.recentIntenseExercise
          ? ClinicalHypothesisType.exercise
          : ClinicalHypothesisType.insulin;
    } else if (acceleration.abs() > config.stressAccelerationThreshold &&
        velocity.abs() < config.stressVelocityCeiling) {
      type = ClinicalHypothesisType.stress;
    }
    if (type == null) return const [];

    return [
      ClinicalHypothesis(
        type: type,
        confidence: residualConfidence(
          residual,
          thresholdMgdl: config.residualThresholdMgdl,
        ),
        rationale: 'Residual ${residual.toStringAsFixed(1)} mg/dL with '
            'velocity ${velocity.toStringAsFixed(2)} mg/dL/min classified '
            'as ${type.name}.',
      ),
    ];
  }
}
