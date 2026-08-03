import 'dart:math' as math;

import 'kalman_filter.dart';

/// Three-tier bucketing of [GlucoseEstimate.sigma] into a human label \u2014
/// independent of [GlucoseEstimate.confidence] (which is the finer-grained,
/// percentage-style figure used for the >=90% "safe to show" gate).
enum GlucoseConfidenceLevel { high, medium, low }

/// One Kalman update's full result: the untouched sensor reading alongside
/// both derived estimates. [observed] is never replaced \u2014 the estimates
/// only ever augment it. See lib/cgm/glucose_estimator.dart.
class GlucoseEstimate {
  const GlucoseEstimate({
    required this.observed,
    required this.estimated,
    required this.estimatedNow,
    required this.velocity,
    required this.confidence,
    required this.sigma,
    required this.lagMinutes,
    required this.residual,
  });

  /// Raw sensor/manual reading, mg/dL \u2014 exactly as measured, never altered.
  final double observed;

  /// Kalman-filtered glucose at the reading's own timestamp, mg/dL.
  final double estimated;

  /// Lag-compensated estimate of the physiological glucose *right now*,
  /// mg/dL \u2014 never a forecast of the future, only of the present instant
  /// (see [GlucoseEstimator.lagMinutes]).
  final double estimatedNow;

  /// Rate of change of [estimated], in mg/dL per minute.
  final double velocity;

  /// Probability-style confidence (0..1) that the true value is within
  /// [GlucoseEstimator.confidenceToleranceMgdl] of [estimatedNow].
  final double confidence;

  /// Standard deviation of [estimatedNow], mg/dL \u2014 accounts for both the
  /// Kalman filter's value variance and its (still uncertain, especially
  /// after few readings) velocity variance. Basis for [confidenceLevel].
  final double sigma;
  /// Minutes [estimatedNow] projects ahead of [observed]/[estimated] — the
  /// interstitial lag it compensates (see [GlucoseEstimator.lagMinutes]).
  final double lagMinutes;

  /// The Kalman filter's innovation for this reading: [observed] minus the
  /// value the filter had already *predicted* right before this update
  /// (i.e. before [observed] was incorporated). Zero for the very first
  /// reading, since there is no prior prediction to diverge from. This is
  /// the raw signal the Past Event Interpreter watches for statistically
  /// significant divergence — see lib/cgm/past_event_interpreter.dart.
  final double residual;
  double get confidencePercent => confidence * 100;

  GlucoseConfidenceLevel get confidenceLevel {
    if (sigma < 3) return GlucoseConfidenceLevel.high;
    if (sigma < 6) return GlucoseConfidenceLevel.medium;
    return GlucoseConfidenceLevel.low;
  }

  /// Per spec: below 90% confidence, [estimatedNow] must never be shown or
  /// used as if it were a primary reading \u2014 only the sensor value can be.
  bool get isEstimatedNowReliable => confidence >= 0.9;
}

/// Estimates the *current* physiological glucose from a stream of CGM/manual
/// readings, partially compensating the sensor's ~10\u201315 minute interstitial
/// lag. This never predicts the future: every estimate is derived only from
/// readings already received. Kept independent of any UI or storage type so
/// it can be reused by future modules (hypo/hyper prediction, IOB, COB, ISF,
/// ICR estimation, Nuno's decision engine) exactly as-is.
class GlucoseEstimator {
  GlucoseEstimator({
    this.measurementNoise = 9.0,
    this.processNoiseValue = 2.0,
    this.processNoiseVelocity = 0.02,
    this.lagMinutes = 10.0,
    this.confidenceToleranceMgdl = 5.0,
  });

  /// R \u2014 measurement noise variance, mg/dL\u00b2 (9 \u2192 \u03c3 \u2248 3 mg/dL).
  final double measurementNoise;

  /// Q term for the glucose state \u2014 a simple starting point, tune with data.
  final double processNoiseValue;

  /// Q term for the velocity state \u2014 a simple starting point, tune with data.
  final double processNoiseVelocity;

  /// Minutes of interstitial delay compensated by [GlucoseEstimate.estimatedNow].
  /// Starts at 10 (not the higher end of the usual 10\u201315min range) per spec.
  final double lagMinutes;

  /// Tolerance band (mg/dL) used to turn sigma into a probability-style
  /// confidence percentage \u2014 see [GlucoseEstimate.confidence].
  final double confidenceToleranceMgdl;

  KalmanFilter2D? _filter;
  DateTime? _lastReadingAt;

  /// Feeds one new reading through predict \u2192 update \u2192 lag compensation.
  /// Readings must be supplied in non-decreasing timestamp order; call
  /// [reset] first if starting over (e.g. a new sensor).
  GlucoseEstimate addReading(double mgdl, DateTime at) {
    final filter = _filter;
    final lastAt = _lastReadingAt;
    if (filter == null || lastAt == null) {
      final fresh = KalmanFilter2D(
        initialValue: mgdl,
        measurementNoise: measurementNoise,
        processNoiseValue: processNoiseValue,
        processNoiseVelocity: processNoiseVelocity,
      );
      fresh.update(mgdl);
      _filter = fresh;
      _lastReadingAt = at;
      return _estimateFrom(fresh, mgdl, residual: 0);
    }

    final dtMinutes = at.difference(lastAt).inSeconds / 60.0;
    if (dtMinutes > 0) filter.predict(dtMinutes);
    final predictedValue = filter.value;
    filter.update(mgdl);
    _lastReadingAt = at;
    return _estimateFrom(filter, mgdl, residual: mgdl - predictedValue);
  }

  GlucoseEstimate _estimateFrom(
    KalmanFilter2D filter,
    double observed, {
    required double residual,
  }) {
    // estimatedNow = value + velocity * lag is a linear combination of both
    // states, so its uncertainty must account for the velocity's own
    // variance (and its covariance with the value), not just the value's
    // variance — otherwise a single reading (velocity still unknown) would
    // look artificially confident.
    final varianceNow = filter.valueVariance +
        2 * lagMinutes * filter.valueVelocityCovariance +
        lagMinutes * lagMinutes * filter.velocityVariance;
    final sigma = math.sqrt(math.max(varianceNow, 0));
    return GlucoseEstimate(
      observed: observed,
      estimated: filter.value,
      estimatedNow: filter.value + filter.velocity * lagMinutes,
      velocity: filter.velocity,
      confidence: _confidenceFromSigma(sigma),
      sigma: sigma,
      lagMinutes: lagMinutes,
      residual: residual,
    );
  }

  double _confidenceFromSigma(double sigma) {
    if (sigma <= 0) return 1.0;
    return _erf(confidenceToleranceMgdl / (sigma * math.sqrt2)).clamp(0.0, 1.0);
  }

  /// Resets all state \u2014 the next [addReading] starts a brand-new filter.
  void reset() {
    _filter = null;
    _lastReadingAt = null;
  }
}

/// Abramowitz & Stegun formula 7.1.26 approximation (max error ~1.5e-7) \u2014
/// `dart:math` has no built-in error function.
double _erf(double x) {
  final sign = x < 0 ? -1.0 : 1.0;
  final ax = x.abs();
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;
  final t = 1.0 / (1.0 + p * ax);
  final y = 1.0 -
      (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * math.exp(-ax * ax);
  return sign * y;
}
