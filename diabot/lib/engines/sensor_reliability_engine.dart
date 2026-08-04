import 'evidence_fusion_engine.dart';

/// Judges the CGM reading's trustworthiness only — never the patient's
/// physiological state. See docs/fsm/sensor_reliability_engine.mmd.
class SensorReliability {
  const SensorReliability({
    required this.confidence,
    this.probableLag = false,
    this.probableCompression = false,
    this.probableSensorError = false,
  });

  final double confidence;
  final bool probableLag;
  final bool probableCompression;
  final bool probableSensorError;
}

/// v1 heuristics over a single turn's [EvidenceSet] — no raw reading
/// history yet, so compression-artifact detection is coarse; refine once
/// ContradictionEngine can cross-check against a short reading window.
class SensorReliabilityEngine {
  const SensorReliabilityEngine._();

  static const fastVelocityThreshold = 2.0; // mg/dL per minute
  static const largeResidualThreshold = 15.0; // mg/dL
  static const lowConfidenceThreshold = 0.5;
  static const veryLowConfidenceThreshold = 0.3;

  static SensorReliability assess(EvidenceSet evidence) {
    final glucose = evidence.glucoseEvidence;
    final trend = evidence.trendEvidence;

    final fastChange = trend.velocity.abs() > fastVelocityThreshold;
    final largeResidual = glucose.residual.abs() > largeResidualThreshold;
    final lowConfidence = glucose.kalmanConfidence < lowConfidenceThreshold;

    final probableLag = fastChange && largeResidual && lowConfidence;
    final probableCompression = !probableLag &&
        trend.direction == 'falling' &&
        lowConfidence &&
        !evidence.symptomEvidence.hasHypoSymptoms;
    final probableSensorError = !probableLag &&
        !probableCompression &&
        glucose.kalmanConfidence < veryLowConfidenceThreshold;

    return SensorReliability(
      confidence: glucose.kalmanConfidence,
      probableLag: probableLag,
      probableCompression: probableCompression,
      probableSensorError: probableSensorError,
    );
  }
}
