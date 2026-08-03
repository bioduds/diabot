import 'package:diabai/cgm/glucose_estimator.dart';
import 'package:diabai/cgm/kalman_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KalmanFilter2D', () {
    test('update() pulls the estimate toward the measurement and shrinks variance', () {
      final filter = KalmanFilter2D(
        initialValue: 100,
        measurementNoise: 9,
        processNoiseValue: 2,
        processNoiseVelocity: 0.02,
      );
      final varianceBefore = filter.valueVariance;

      filter.update(120);

      expect(filter.value, greaterThan(100));
      expect(filter.value, lessThan(120));
      expect(filter.valueVariance, lessThan(varianceBefore));
    });

    test('predict() advances the value by velocity * dt and grows variance', () {
      final filter = KalmanFilter2D(
        initialValue: 100,
        initialVelocity: 2,
        measurementNoise: 9,
        processNoiseValue: 2,
        processNoiseVelocity: 0.02,
      );
      final varianceBefore = filter.valueVariance;

      filter.predict(5);

      expect(filter.value, closeTo(110, 1e-9));
      expect(filter.velocity, closeTo(2, 1e-9));
      expect(filter.valueVariance, greaterThan(varianceBefore));
    });
  });

  group('GlucoseEstimator', () {
    test('never alters the raw observed value', () {
      final estimator = GlucoseEstimator();
      final estimate = estimator.addReading(152, DateTime(2026, 1, 1, 8));
      expect(estimate.observed, 152);
    });

    test('residual is zero on the first reading (no prior prediction exists)', () {
      final estimator = GlucoseEstimator();
      final estimate = estimator.addReading(140, DateTime(2026, 1, 1, 8));
      expect(estimate.residual, 0);
    });

    test('residual reflects the gap between observed and the pre-update prediction', () {
      final estimator = GlucoseEstimator();
      final start = DateTime(2026, 1, 1, 8);
      estimator.addReading(100, start);
      // Stable readings settle the filter near a ~0 velocity, so its next
      // prediction stays close to 100 \u2014 a sudden jump to 160 should
      // produce a large positive residual (observed far above predicted).
      for (var i = 1; i <= 5; i++) {
        estimator.addReading(100, start.add(Duration(minutes: 5 * i)));
      }
      final jump = estimator.addReading(
        160,
        start.add(const Duration(minutes: 30)),
      );
      expect(jump.residual, greaterThan(30));
    });

    test('repeated stable readings converge and confidence improves well past a single reading', () {
      final estimator = GlucoseEstimator();
      final start = DateTime(2026, 1, 1, 8);
      final first = estimator.addReading(140, start);
      GlucoseEstimate estimate = first;
      for (var i = 1; i <= 30; i++) {
        estimate = estimator.addReading(
          140,
          start.add(Duration(minutes: 5 * i)),
        );
      }

      expect(estimate.estimated, closeTo(140, 2));
      expect(estimate.confidence, greaterThan(first.confidence));
      expect(estimate.sigma, lessThan(first.sigma));
      expect(estimate.confidenceLevel, isNot(GlucoseConfidenceLevel.low));
    });

    test('the >=90% reliability gate is reachable once uncertainty is low enough', () {
      // Uses a looser tolerance than the production default purely to prove
      // the gate mechanics (default constants are still being tuned with
      // real device data \u2014 see repo memory notes).
      final estimator = GlucoseEstimator(confidenceToleranceMgdl: 10);
      final start = DateTime(2026, 1, 1, 8);
      GlucoseEstimate estimate = estimator.addReading(140, start);
      for (var i = 1; i <= 30; i++) {
        estimate = estimator.addReading(
          140,
          start.add(Duration(minutes: 5 * i)),
        );
      }

      expect(estimate.confidence, greaterThanOrEqualTo(0.9));
      expect(estimate.isEstimatedNowReliable, isTrue);
    });

    test('a single reading alone is not yet reliable enough for estimatedNow', () {
      final estimator = GlucoseEstimator();
      final estimate = estimator.addReading(150, DateTime(2026, 1, 1, 8));
      expect(estimate.isEstimatedNowReliable, isFalse);
    });

    test('a rising trend yields positive velocity and estimatedNow above estimated', () {
      final estimator = GlucoseEstimator();
      final start = DateTime(2026, 1, 1, 8);
      GlucoseEstimate estimate = estimator.addReading(100, start);
      for (var i = 1; i <= 5; i++) {
        estimate = estimator.addReading(
          100 + 10.0 * i,
          start.add(Duration(minutes: 5 * i)),
        );
      }

      expect(estimate.velocity, greaterThan(0));
      expect(estimate.estimatedNow, greaterThan(estimate.estimated));
    });

    test('a falling trend yields negative velocity and estimatedNow below estimated', () {
      final estimator = GlucoseEstimator();
      final start = DateTime(2026, 1, 1, 8);
      GlucoseEstimate estimate = estimator.addReading(200, start);
      for (var i = 1; i <= 5; i++) {
        estimate = estimator.addReading(
          200 - 10.0 * i,
          start.add(Duration(minutes: 5 * i)),
        );
      }

      expect(estimate.velocity, lessThan(0));
      expect(estimate.estimatedNow, lessThan(estimate.estimated));
    });

    test('reset() makes the next reading behave like a brand-new filter', () {
      final estimator = GlucoseEstimator();
      final start = DateTime(2026, 1, 1, 8);
      for (var i = 0; i <= 5; i++) {
        estimator.addReading(140, start.add(Duration(minutes: 5 * i)));
      }
      estimator.reset();

      final estimate = estimator.addReading(90, start.add(const Duration(hours: 5)));
      expect(estimate.estimated, closeTo(90, 1e-6));
      expect(estimate.isEstimatedNowReliable, isFalse);
    });

    test('confidenceLevel buckets match the documented sigma thresholds', () {
      const high = GlucoseEstimate(
        observed: 100,
        estimated: 100,
        estimatedNow: 100,
        velocity: 0,
        confidence: 0.99,
        sigma: 2.9,
        lagMinutes: 10,
        residual: 0,
      );
      const medium = GlucoseEstimate(
        observed: 100,
        estimated: 100,
        estimatedNow: 100,
        velocity: 0,
        confidence: 0.6,
        sigma: 4,
        lagMinutes: 10,
        residual: 0,
      );
      const low = GlucoseEstimate(
        observed: 100,
        estimated: 100,
        estimatedNow: 100,
        velocity: 0,
        confidence: 0.2,
        sigma: 7,
        lagMinutes: 10,
        residual: 0,
      );

      expect(high.confidenceLevel, GlucoseConfidenceLevel.high);
      expect(medium.confidenceLevel, GlucoseConfidenceLevel.medium);
      expect(low.confidenceLevel, GlucoseConfidenceLevel.low);
    });
  });
}
