import 'contradiction_engine.dart';
import 'hypothesis_engine.dart';
import 'sensor_reliability_engine.dart';

/// The result of one [ConfidenceEngine.compute] call \u2014 how much DiabAI
/// should trust its own reasoning this turn, feeding ResponseBuilder's tone
/// bucket. Never a claim about the patient's actual health.
class AssessmentConfidence {
  const AssessmentConfidence({
    required this.overall,
    required this.tier,
    required this.perHypothesis,
  });

  /// 0..1, combining the top hypothesis's confidence with sensor
  /// reliability and any flagged contradictions.
  final double overall;

  /// One of docs/fsm/confidence_engine.mmd's `confidenceTiers`: alta/media/baixa.
  final String tier;

  final Map<ClinicalHypothesisType, double> perHypothesis;
}

class ConfidenceEngineConfig {
  const ConfidenceEngineConfig({
    this.altaThreshold = 0.75,
    this.mediaThreshold = 0.45,
    this.contradictionPenalty = 0.15,
    this.unreliableSensorFactor = 0.85,
  });

  final double altaThreshold;
  final double mediaThreshold;

  /// Subtracted from [AssessmentConfidence.overall] for each
  /// [ContradictionReport] flag \u2014 disagreement always lowers trust.
  final double contradictionPenalty;

  /// Multiplied into [AssessmentConfidence.overall] when
  /// [SensorReliability] suspects lag, compression, or sensor error.
  final double unreliableSensorFactor;
}

/// See docs/fsm/confidence_engine.mmd. Combines the ranked hypotheses,
/// sensor reliability, and any flagged contradictions into one overall
/// confidence score and tier \u2014 computes no diagnosis, stores nothing,
/// never talks to the user directly.
class ConfidenceEngine {
  const ConfidenceEngine._();

  static AssessmentConfidence compute(
    List<ClinicalHypothesis> hypotheses,
    SensorReliability reliability,
    ContradictionReport contradictions, {
    ConfidenceEngineConfig config = const ConfidenceEngineConfig(),
  }) {
    final perHypothesis = <ClinicalHypothesisType, double>{
      for (final hypothesis in hypotheses) hypothesis.type: hypothesis.confidence,
    };

    var overall = hypotheses.isEmpty ? 0.0 : hypotheses.first.confidence;

    final sensorUnreliable = reliability.probableLag ||
        reliability.probableCompression ||
        reliability.probableSensorError;
    if (sensorUnreliable) {
      overall *= config.unreliableSensorFactor;
    }

    overall -= contradictions.flags.length * config.contradictionPenalty;
    overall = overall.clamp(0.0, 1.0);

    final String tier;
    if (overall >= config.altaThreshold) {
      tier = 'alta';
    } else if (overall >= config.mediaThreshold) {
      tier = 'media';
    } else {
      tier = 'baixa';
    }

    return AssessmentConfidence(
      overall: overall,
      tier: tier,
      perHypothesis: perHypothesis,
    );
  }
}
