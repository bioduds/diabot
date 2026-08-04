import 'evidence_fusion_engine.dart';
import 'hypothesis_engine.dart';

/// Coarse physiological trajectory, not a diagnosis \u2014 see
/// docs/fsm/physiological_state_engine.mmd. Order matches
/// FsmContract.physiologicalPhases exactly.
enum PhysiologicalPhase {
  absorbingCarbs,
  insulinDominant,
  acceleratingDrop,
  hypoRisk,
  recovering,
  stabilizing,
}

class PhysiologicalStateEngineConfig {
  const PhysiologicalStateEngineConfig({
    this.hypoRiskThresholdMgdl = 80,
    this.risingVelocityThreshold = 0.6,
    this.fallingVelocityThreshold = 0.6,
    this.acceleratingThreshold = 0.3,
  });

  /// Below this estimated glucose, a falling trend is treated as an
  /// imminent-hypo risk rather than a plain accelerating drop.
  final double hypoRiskThresholdMgdl;
  final double risingVelocityThreshold;
  final double fallingVelocityThreshold;
  final double acceleratingThreshold;
}

/// See docs/fsm/physiological_state_engine.mmd. Recomputes the current
/// coarse phase from this turn's [EvidenceSet] and recent hypothesis
/// [history] (this session only, no persisted table in v1). Never stores
/// an event, never talks to the user, no Emergency/Priority Engine impact
/// of its own.
class PhysiologicalStateEngine {
  const PhysiologicalStateEngine._();

  /// Hypothesis types that mark a recent low, used to detect [recovering].
  static const _recentLowTypes = {
    ClinicalHypothesisType.trueHypoglycemia,
    ClinicalHypothesisType.sensorLag,
    ClinicalHypothesisType.compressionArtifact,
  };

  static PhysiologicalPhase classify(
    EvidenceSet evidence,
    List<ClinicalHypothesis> history, {
    PhysiologicalStateEngineConfig config =
        const PhysiologicalStateEngineConfig(),
  }) {
    final glucose = evidence.glucoseEvidence;
    final trend = evidence.trendEvidence;

    final nearHypo = glucose.estimatedNow < config.hypoRiskThresholdMgdl;
    final falling = trend.velocity <= -config.fallingVelocityThreshold;
    final rising = trend.velocity >= config.risingVelocityThreshold;
    final accelerating = trend.acceleration <= -config.acceleratingThreshold;

    // Order is priority, most safety-relevant first: proximity to
    // hypoglycemia always wins over a plain accelerating drop, and a
    // rising trend only reads as recovery when a recent low justifies it.
    if (nearHypo && falling) {
      return PhysiologicalPhase.hypoRisk;
    }
    if (falling && accelerating) {
      return PhysiologicalPhase.acceleratingDrop;
    }
    if (rising && history.any((h) => _recentLowTypes.contains(h.type))) {
      return PhysiologicalPhase.recovering;
    }
    if (rising && evidence.mealEvidence.hasActiveCarbs) {
      return PhysiologicalPhase.absorbingCarbs;
    }
    if (falling && evidence.insulinEvidence.hasActiveBolus) {
      return PhysiologicalPhase.insulinDominant;
    }
    return PhysiologicalPhase.stabilizing;
  }
}
