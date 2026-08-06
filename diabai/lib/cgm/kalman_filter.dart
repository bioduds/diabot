/// Minimal 2-state (glucose, velocity) linear Kalman filter for a scalar
/// physiological signal measured periodically with additive Gaussian noise.
///
/// Deliberately UI/CGM-agnostic \u2014 [GlucoseEstimator] (glucose_estimator.dart)
/// is the only glucose-specific layer on top of this, so the same filter can
/// be reused for any other slowly-varying vital sign later.
///
/// State: `x = [value, velocity]^T` (velocity in value-units per minute).
/// Transition: `x(k+1) = A x(k) + w`, `A = [[1, dt], [0, 1]]`.
/// Measurement: `z = H x + v`, `H = [1, 0]` (only the value is observed).
class KalmanFilter2D {
  KalmanFilter2D({
    required double initialValue,
    double initialVelocity = 0,
    required this.measurementNoise,
    required this.processNoiseValue,
    required this.processNoiseVelocity,
    double initialValueVariance = 25,
    double initialVelocityVariance = 4,
  })  : _x0 = initialValue,
        _x1 = initialVelocity,
        _p00 = initialValueVariance,
        _p01 = 0,
        _p10 = 0,
        _p11 = initialVelocityVariance;

  /// R \u2014 measurement noise variance, in value-unit\u00b2 (e.g. mg/dL\u00b2).
  final double measurementNoise;

  /// Q diagonal term added to the value's variance each predict step.
  final double processNoiseValue;

  /// Q diagonal term added to the velocity's variance each predict step.
  final double processNoiseVelocity;

  double _x0;
  double _x1;
  double _p00;
  double _p01;
  double _p10;
  double _p11;

  /// Current filtered value estimate.
  double get value => _x0;

  /// Current filtered rate of change, per minute.
  double get velocity => _x1;

  /// Variance of [value] \u2014 sqrt of this is the estimate's standard deviation.
  double get valueVariance => _p00;
  /// Variance of [velocity], in (mg/dL per minute)².
  double get velocityVariance => _p11;

  /// Covariance between the value and velocity states — needed to size the
  /// uncertainty of any linear combination of the two (e.g. a lag-projected
  /// "value now" estimate), not just of the value alone.
  double get valueVelocityCovariance => (_p01 + _p10) / 2;
  /// Advances the state by [dtMinutes] with no new measurement: `x = A x`,
  /// `P = A P A^T + Q` (Q applied as independent diagonal terms).
  void predict(double dtMinutes) {
    final x0 = _x0 + _x1 * dtMinutes;
    final p00 = _p00 +
        dtMinutes * (_p01 + _p10) +
        dtMinutes * dtMinutes * _p11 +
        processNoiseValue;
    final p01 = _p01 + dtMinutes * _p11;
    final p10 = _p10 + dtMinutes * _p11;
    final p11 = _p11 + processNoiseVelocity;

    _x0 = x0;
    _p00 = p00;
    _p01 = p01;
    _p10 = p10;
    _p11 = p11;
    // _x1 (velocity) is unchanged by A under a constant-velocity model.
  }

  /// Corrects the prediction with a new measurement [z] of the value.
  void update(double z) {
    final y = z - _x0;
    final s = _p00 + measurementNoise;
    final k0 = _p00 / s;
    final k1 = _p10 / s;

    _x0 += k0 * y;
    _x1 += k1 * y;

    final p00 = (1 - k0) * _p00;
    final p01 = (1 - k0) * _p01;
    final p10 = _p10 - k1 * _p00;
    final p11 = _p11 - k1 * _p01;

    _p00 = p00;
    _p01 = p01;
    _p10 = p10;
    _p11 = p11;
  }

  /// Corrects the state with a direct measurement [vz] of the velocity
  /// state (`H = [0, 1]`) instead of the value \u2014 e.g. a CGM API's own
  /// reported rate-of-change/trend, fused in as an independent observation
  /// of the same rate the value updates only infer indirectly.
  /// [velocityMeasurementNoise] is that observation's own variance (R).
  void updateVelocity(double vz, double velocityMeasurementNoise) {
    final y = vz - _x1;
    final s = _p11 + velocityMeasurementNoise;
    final k0 = _p01 / s;
    final k1 = _p11 / s;

    _x0 += k0 * y;
    _x1 += k1 * y;

    final p00 = _p00 - k0 * _p10;
    final p01 = _p01 - k0 * _p11;
    final p10 = (1 - k1) * _p10;
    final p11 = (1 - k1) * _p11;

    _p00 = p00;
    _p01 = p01;
    _p10 = p10;
    _p11 = p11;
  }
}
