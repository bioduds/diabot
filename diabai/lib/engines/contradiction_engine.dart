import 'evidence_fusion_engine.dart';
import 'hypothesis_engine.dart';
import 'sensor_reliability_engine.dart';

/// One flagged disagreement between the sensor, the Kalman estimate, and
/// reported symptoms \u2014 named to match docs/fsm/contradiction_engine.mmd's
/// `conflictPatterns` exactly.
class ContradictionFlag {
  const ContradictionFlag({required this.pattern, required this.rationale});

  final String pattern;
  final String rationale;
}

/// The result of one [ContradictionEngine.detect] call. Purely descriptive:
/// flagging a conflict resolves nothing and issues no treatment guidance
/// \u2014 that is the Confidence Engine and Response Builder's job.
class ContradictionReport {
  const ContradictionReport({this.flags = const []});

  final List<ContradictionFlag> flags;

  bool get hasContradiction => flags.isNotEmpty;

  bool hasPattern(String pattern) =>
      flags.any((flag) => flag.pattern == pattern);
}

class ContradictionEngineConfig {
  const ContradictionEngineConfig({
    this.hypoglycemiaThresholdMgdl = 70,
    this.hyperglycemiaThresholdMgdl = 180,
    this.kalmanGapThresholdMgdl = 15,
    this.acceleratingDropVelocityThreshold = 1.0,
    this.acceleratingDropAccelerationThreshold = 0.3,
  });

  final double hypoglycemiaThresholdMgdl;
  final double hyperglycemiaThresholdMgdl;

  /// Minimum |estimatedNow - observed| gap (mg/dL) to call the Kalman
  /// estimate meaningfully lower than the raw sensor reading.
  final double kalmanGapThresholdMgdl;
  final double acceleratingDropVelocityThreshold;
  final double acceleratingDropAccelerationThreshold;
}

/// See docs/fsm/contradiction_engine.mmd. Flags disagreement between the
/// sensor, the Kalman estimate, and reported symptoms \u2014 never resolves a
/// conflict, never stores an event, never talks to the user.
class ContradictionEngine {
  const ContradictionEngine._();

  static ContradictionReport detect(
    EvidenceSet evidence,
    SensorReliability reliability,
    List<ClinicalHypothesis> hypotheses, {
    ContradictionEngineConfig config = const ContradictionEngineConfig(),
  }) {
    final glucose = evidence.glucoseEvidence;
    final trend = evidence.trendEvidence;
    final symptoms = evidence.symptomEvidence;
    final flags = <ContradictionFlag>[];

    if (glucose.estimatedNow > config.hyperglycemiaThresholdMgdl &&
        symptoms.hasHypoSymptoms) {
      flags.add(ContradictionFlag(
        pattern: 'sensorHighStrongSymptoms',
        rationale: 'Estimated glucose '
            '${glucose.estimatedNow.toStringAsFixed(0)} mg/dL is high, but '
            'hypoglycemia symptoms were reported.',
      ));
    }

    final kalmanGap = glucose.estimatedNow - glucose.observed;
    if (kalmanGap <= -config.kalmanGapThresholdMgdl &&
        trend.velocity <= -config.acceleratingDropVelocityThreshold &&
        trend.acceleration <= -config.acceleratingDropAccelerationThreshold) {
      final lagHypothesis = _confidenceFor(
        hypotheses,
        ClinicalHypothesisType.sensorLag,
      );
      final corroboration = lagHypothesis == null
          ? ''
          : ' (consistent with a sensorLag hypothesis at '
              '${(lagHypothesis * 100).toStringAsFixed(0)}% confidence)';
      flags.add(ContradictionFlag(
        pattern: 'kalmanMuchLowerAcceleratingDrop',
        rationale: 'Projected glucose is ${kalmanGap.abs().toStringAsFixed(0)}'
            ' mg/dL below the raw sensor reading and accelerating downward, '
            'suggesting an imminent low the sensor has not caught up to'
            '$corroboration.',
      ));
    }

    if (glucose.estimatedNow >= config.hypoglycemiaThresholdMgdl &&
        glucose.estimatedNow <= config.hyperglycemiaThresholdMgdl &&
        (symptoms.hasHypoSymptoms || symptoms.hasHyperSymptoms)) {
      flags.add(ContradictionFlag(
        pattern: 'sensorNormalWithSymptoms',
        rationale: 'Estimated glucose '
            '${glucose.estimatedNow.toStringAsFixed(0)} mg/dL is within the '
            'normal range, but symptoms were reported.',
      ));
    }

    return ContradictionReport(flags: flags);
  }

  static double? _confidenceFor(
    List<ClinicalHypothesis> hypotheses,
    ClinicalHypothesisType type,
  ) {
    for (final hypothesis in hypotheses) {
      if (hypothesis.type == type) return hypothesis.confidence;
    }
    return null;
  }
}
