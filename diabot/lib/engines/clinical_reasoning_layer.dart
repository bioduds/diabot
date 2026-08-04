import '../cgm/glucose_estimator.dart';
import '../events.dart';
import 'confidence_engine.dart';
import 'contradiction_engine.dart';
import 'evidence_fusion_engine.dart';
import 'hypothesis_engine.dart';
import 'physiological_state_engine.dart';
import 'sensor_reliability_engine.dart';

/// One turn's complete clinical judgment — the only object EmergencyEngine
/// and ResponseBuilder consume for anything glucose-related. See
/// docs/fsm/clinical_reasoning_layer.mmd.
class ClinicalAssessment {
  const ClinicalAssessment({
    required this.hypotheses,
    required this.dominantHypothesis,
    required this.confidence,
    required this.evidence,
    required this.contradictions,
    required this.physiologicalPhase,
    this.recommendations = const [],
    this.questions = const [],
  });

  /// All ranked candidates, highest confidence first.
  final List<ClinicalHypothesis> hypotheses;

  /// The top-ranked entry of [hypotheses], or null when it is empty (a
  /// normal, unremarkable reading generates no hypothesis at all).
  final ClinicalHypothesis? dominantHypothesis;

  final AssessmentConfidence confidence;
  final EvidenceSet evidence;
  final ContradictionReport contradictions;
  final PhysiologicalPhase physiologicalPhase;

  /// Descriptive/clarifying only — never a dosing or treatment instruction.
  /// v1 leaves these empty; Phase 7's ResponseBuilder and adaptive-question
  /// selection key off [dominantHypothesis] directly instead of duplicating
  /// that mapping here.
  final List<String> recommendations;
  final List<String> questions;
}

/// See docs/fsm/clinical_reasoning_layer.mmd. Composes EvidenceFusionEngine,
/// SensorReliabilityEngine, HypothesisEngine, ContradictionEngine,
/// ConfidenceEngine, and PhysiologicalStateEngine into one [ClinicalAssessment]
/// per turn — the sole owner of clinical judgment in DiabAI. Never touches
/// DiabAIGlobalState/EventStatus and never talks to the user; EmergencyEngine
/// and ResponseBuilder are its only consumers.
class ClinicalReasoningLayer {
  const ClinicalReasoningLayer._();

  static ClinicalAssessment assess({
    required GlucoseEstimate estimate,
    required DateTime at,
    required List<EventInstance> stack,
    TemporalContext? temporalContext,
    ProfileContext? profileContext,
    GlucoseEstimate? previousEstimate,
    DateTime? previousAt,
  }) {
    final evidence = EvidenceFusionEngine.fuse(
      estimate: estimate,
      at: at,
      stack: stack,
      temporalContext: temporalContext,
      previousEstimate: previousEstimate,
      previousAt: previousAt,
    );

    final reliability = SensorReliabilityEngine.assess(evidence);
    final hypotheses = HypothesisEngine.generate(evidence, reliability);
    final contradictions =
        ContradictionEngine.detect(evidence, reliability, hypotheses);
    final confidence =
        ConfidenceEngine.compute(hypotheses, reliability, contradictions);
    final physiologicalPhase =
        PhysiologicalStateEngine.classify(evidence, hypotheses);

    return ClinicalAssessment(
      hypotheses: hypotheses,
      dominantHypothesis: hypotheses.isEmpty ? null : hypotheses.first,
      confidence: confidence,
      evidence: evidence,
      contradictions: contradictions,
      physiologicalPhase: physiologicalPhase,
    );
  }
}
