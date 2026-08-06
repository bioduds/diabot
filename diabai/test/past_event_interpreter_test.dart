import 'package:diabai/cgm/glucose_estimator.dart';
import 'package:diabai/cgm/past_event_interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds [values] (mg/dL, 5 minutes apart starting at [start]) through a
/// fresh [GlucoseEstimator] and returns the parallel sample/estimate lists
/// [PastEventInterpreter.analyze] expects.
({List<GlucoseSample> samples, List<GlucoseEstimate> estimates}) _series(
  DateTime start,
  List<double> values, {
  Duration step = const Duration(minutes: 5),
}) {
  final estimator = GlucoseEstimator();
  final samples = <GlucoseSample>[];
  final estimates = <GlucoseEstimate>[];
  for (var i = 0; i < values.length; i++) {
    final at = start.add(step * i);
    estimates.add(estimator.addReading(values[i], at));
    samples.add(GlucoseSample(at: at, mgdl: values[i]));
  }
  return (samples: samples, estimates: estimates);
}

void main() {
  group('PastEventInterpreter', () {
    test('produces no hypothesis for stable, well-predicted readings', () {
      final series = _series(
        DateTime(2026, 1, 1, 12),
        List.filled(13, 100.0),
      );

      final hypotheses = const PastEventInterpreter().analyze(
        samples: series.samples,
        estimates: series.estimates,
      );

      expect(hypotheses, isEmpty);
    });

    test('classifies a sudden unexplained rise as a meal hypothesis', () {
      final series = _series(DateTime(2026, 1, 1, 12), [
        100, 100, 100, 100, 100, 100, 100, // stable baseline
        170, // sudden rise
      ]);

      final hypotheses = const PastEventInterpreter().analyze(
        samples: series.samples,
        estimates: series.estimates,
      );

      expect(hypotheses, isNotEmpty);
      expect(hypotheses.single.type, HypothesisType.meal);
      expect(hypotheses.single.status, HypothesisStatus.pending);
      expect(hypotheses.single.magnitude, greaterThan(0));
      expect(hypotheses.single.explanation, contains('Refeição'));
    });

    test('classifies a sudden unexplained fall as an insulin hypothesis', () {
      final series = _series(DateTime(2026, 1, 1, 12), [
        180, 180, 180, 180, 180, 180, 180, // stable baseline
        110, // sudden fall
      ]);

      final hypotheses = const PastEventInterpreter().analyze(
        samples: series.samples,
        estimates: series.estimates,
      );

      expect(hypotheses, isNotEmpty);
      expect(hypotheses.single.type, HypothesisType.insulin);
      expect(hypotheses.single.magnitude, lessThan(0));
    });

    test('a nearby known exercise event reclassifies a fall as exercise', () {
      final series = _series(DateTime(2026, 1, 1, 12), [
        180, 180, 180, 180, 180, 180, 180,
        110,
      ]);
      final fallAt = series.samples.last.at;

      final hypotheses = const PastEventInterpreter().analyze(
        samples: series.samples,
        estimates: series.estimates,
        knownEvents: [
          KnownContextEvent(
            type: HypothesisType.exercise,
            at: fallAt.subtract(const Duration(minutes: 10)),
          ),
        ],
      );

      expect(hypotheses.single.type, HypothesisType.exercise);
    });

    test('a nearby known meal event suppresses the rise hypothesis entirely', () {
      final series = _series(DateTime(2026, 1, 1, 12), [
        100, 100, 100, 100, 100, 100, 100,
        170,
      ]);
      final riseAt = series.samples.last.at;

      final hypotheses = const PastEventInterpreter().analyze(
        samples: series.samples,
        estimates: series.estimates,
        knownEvents: [
          KnownContextEvent(
            type: HypothesisType.meal,
            at: riseAt.subtract(const Duration(minutes: 5)),
          ),
        ],
      );

      expect(hypotheses, isEmpty);
    });

    test('a slow overnight rise inside the dawn window is not a meal hypothesis', () {
      final samples = [
        GlucoseSample(
          at: DateTime(2026, 1, 1, 5, 25),
          mgdl: 100,
        ),
        GlucoseSample(
          at: DateTime(2026, 1, 1, 5, 30),
          mgdl: 112,
        ),
      ];
      final estimates = [
        const GlucoseEstimate(
          observed: 100,
          estimated: 100,
          estimatedNow: 100,
          velocity: 0,
          confidence: 0.9,
          sigma: 3,
          lagMinutes: 10,
          residual: 0,
        ),
        const GlucoseEstimate(
          observed: 112,
          estimated: 108,
          estimatedNow: 110,
          velocity: 0.3,
          confidence: 0.8,
          sigma: 4,
          lagMinutes: 10,
          residual: 12,
        ),
      ];

      final hypotheses = const PastEventInterpreter().analyze(
        samples: samples,
        estimates: estimates,
      );

      expect(hypotheses.single.type, HypothesisType.dawnPhenomenon);
    });

    test('the same overnight residual outside the dawn window stays a plain rise signal', () {
      final samples = [
        GlucoseSample(at: DateTime(2026, 1, 1, 12, 25), mgdl: 100),
        GlucoseSample(at: DateTime(2026, 1, 1, 12, 30), mgdl: 112),
      ];
      final estimates = [
        const GlucoseEstimate(
          observed: 100,
          estimated: 100,
          estimatedNow: 100,
          velocity: 0,
          confidence: 0.9,
          sigma: 3,
          lagMinutes: 10,
          residual: 0,
        ),
        const GlucoseEstimate(
          observed: 112,
          estimated: 108,
          estimatedNow: 110,
          velocity: 0.3,
          confidence: 0.8,
          sigma: 4,
          lagMinutes: 10,
          residual: 12,
        ),
      ];

      final hypotheses = const PastEventInterpreter().analyze(
        samples: samples,
        estimates: estimates,
      );

      // Velocity (0.3) is below both the meal and dawn thresholds outside
      // the dawn window, so this significant residual yields no hypothesis
      // rather than a false-positive meal classification.
      expect(hypotheses, isEmpty);
    });

    test('adjacent significant residuals of the same type collapse into one hypothesis', () {
      final series = _series(DateTime(2026, 1, 1, 12), [
        100, 100, 100, 100, 100, 100, 100,
        140, 175, // two consecutive rises, both past the threshold
      ]);

      final hypotheses = const PastEventInterpreter().analyze(
        samples: series.samples,
        estimates: series.estimates,
      );

      expect(hypotheses.length, 1);
    });

    test('hypothesis ids are stable across repeated analysis of the same window', () {
      final series = _series(DateTime(2026, 1, 1, 12), [
        100, 100, 100, 100, 100, 100, 100,
        170,
      ]);

      const interpreter = PastEventInterpreter();
      final first = interpreter.analyze(
        samples: series.samples,
        estimates: series.estimates,
      );
      final second = interpreter.analyze(
        samples: series.samples,
        estimates: series.estimates,
      );

      expect(first.single.id, second.single.id);
    });

    test(
        'a sustained rise sampled across many growing refresh windows stays '
        'one evolving hypothesis instead of stacking a duplicate per reading',
        () {
      // Mirrors GlucoseChartPage._refreshHypotheses calling analyze() again
      // on every refresh as the visible window grows sample-by-sample —
      // the exact real-world scenario that used to stack a fresh
      // hypothesis (with a fresh id) on every reading of the same ongoing
      // rise instead of tracking it as a single thread.
      final series = _series(DateTime(2026, 1, 1, 12), [
        100, 100, 100, 100, 100, 100, 100, // stable baseline
        135, 155, 170, 182, 192, // sustained, still-rising divergence
      ]);

      const interpreter = PastEventInterpreter();
      String? firstId;
      var observedMultiSampleThread = false;
      for (var end = 8; end <= series.samples.length; end++) {
        final hypotheses = interpreter.analyze(
          samples: series.samples.sublist(0, end),
          estimates: series.estimates.sublist(0, end),
        );
        expect(hypotheses.length, 1,
            reason: 'growing window up to sample $end should still track a '
                'single thread, not spawn a duplicate');
        final hypothesis = hypotheses.single;
        firstId ??= hypothesis.id;
        expect(hypothesis.id, firstId,
            reason: "the thread's identity must not change as later, more "
                'readings of the same rise arrive');
        expect(hypothesis.type, HypothesisType.meal);
        final observationCount = hypothesis.evidence['observationCount'];
        if (observationCount != null && (observationCount as int) > 1) {
          observedMultiSampleThread = true;
          // The succinct explanation format (request #3a) always names the
          // thread's own fixed CauseTime/estimatedStart, whether it's the
          // first observation or a later refresh of the same thread —
          // there's no separate "still observing" narrative anymore.
          expect(hypothesis.evidence['firstObservedAt'], isNotNull);
        }
      }

      expect(observedMultiSampleThread, isTrue,
          reason: 'the growing window should merge at least two readings '
              'into the same thread at some point');
    });

    test(
        'estimatedStart and effectWindowEnd reflect the cause-type CauseTime '
        'latency and EffectWindow duration', () {
      final series = _series(DateTime(2026, 1, 1, 12), [
        100, 100, 100, 100, 100, 100, 100,
        170,
      ]);

      final hypothesis = const PastEventInterpreter()
          .analyze(samples: series.samples, estimates: series.estimates)
          .single;

      expect(hypothesis.type, HypothesisType.meal);
      expect(hypothesis.estimatedStart,
          hypothesis.estimatedPeak.subtract(const Duration(minutes: 15)));
      expect(hypothesis.effectWindowEnd,
          hypothesis.estimatedPeak.add(const Duration(minutes: 180)));
    });

    test(
        'a same-type reading farther apart than the old flat dedupe window '
        'still merges into one thread as long as it is within the '
        "cause's EffectWindow", () {
      final series = _series(DateTime(2026, 1, 1, 12), [
        100, 100, 100, 100, 100, 100, 100, // baseline (+0..+30min)
        170, // meal rise at +35min
        170, 170, 170, 170, // settles (+40..+55min)
        230, // second rise at +60min: 25min after detection of the first
        //    (beyond the old 15-minute flat dedupeWindow) but still well
        //    inside meal's ~180-minute EffectWindow.
      ]);

      final hypotheses = const PastEventInterpreter().analyze(
        samples: series.samples,
        estimates: series.estimates,
      );

      expect(hypotheses.length, 1,
          reason: "the second rise is still within the first reading's "
              'EffectWindow, so it threads into the same hypothesis '
              'instead of starting a new one');
      expect(hypotheses.single.type, HypothesisType.meal);
      expect(hypotheses.single.evidence['observationCount'],
          greaterThanOrEqualTo(2));
    });

    test(
        'a same-type reading arriving after the EffectWindow has elapsed '
        'starts a new hypothesis instead of merging', () {
      final series = _series(DateTime(2026, 1, 1, 12), [
        100, 100, 100, 100, 100, 100, 100, // baseline (+0..+30min)
        170, // meal rise at +35min; EffectWindow closes ~180min later
        ...List.filled(42, 170.0), // flat, well past the EffectWindow
        230, // an independent later rise the original meal can no longer
        //    explain
      ]);

      final hypotheses = const PastEventInterpreter().analyze(
        samples: series.samples,
        estimates: series.estimates,
      );

      expect(hypotheses.length, 2,
          reason: "the second rise arrives after the first reading's "
              'EffectWindow has elapsed, so it can no longer explain new '
              'divergence and a new, independent hypothesis is created');
    });

    test('copyWith updates only the requested fields', () {
      final hypothesis = EventHypothesis(
        id: 'hyp_1',
        type: HypothesisType.meal,
        estimatedStart: _fixedStart,
        estimatedPeak: _fixedPeak,
        effectWindowEnd: _fixedPeak.add(const Duration(hours: 3)),
        confidence: 0.7,
        magnitude: 20,
        explanation: 'test',
        evidence: const {},
        status: HypothesisStatus.pending,
      );

      final corrected = hypothesis.copyWith(
        type: HypothesisType.exercise,
        status: HypothesisStatus.corrected,
      );

      expect(corrected.type, HypothesisType.exercise);
      expect(corrected.status, HypothesisStatus.corrected);
      expect(corrected.id, hypothesis.id);
      expect(corrected.magnitude, hypothesis.magnitude);
    });
  });
}

final _fixedStart = DateTime(2026, 1, 1, 11, 55);
final _fixedPeak = DateTime(2026, 1, 1, 12);
