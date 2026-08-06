import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'cgm/glucose_estimator.dart';
import 'cgm/past_event_interpreter.dart';
import 'cgm_sync_engine.dart';
import 'librelinkup.dart';
import 'local_db.dart';
import 'profile_engine.dart';
import 'profile_view.dart';

enum _ChartMenuAction {
  clearDebugData,
  diagnostics,
  initModel,
  clearConversation,
  signOut,
}

/// Tri-state opacity toggle for the Timeline's hypothesis markers — a
/// small dedicated button placed right on the chart (never buried in the
/// [_ChartMenuAction] app-bar menu), since it's a display preference about
/// the chart itself, cycled opaque → semitransparent → invisible →
/// opaque. Persisted via [SharedPreferences] so it survives navigating
/// away and back.
enum _MarkerVisibility { opaque, translucent, hidden }

const String _markerVisibilityPrefsKey = 'hypothesis_marker_visibility';

class _GlucosePoint {
  const _GlucosePoint(this.at, this.mgdl, this.source, {this.isLive = false, this.trend});
  final DateTime at;
  final double mgdl;
  final String source; // 'manual' | 'cgm'
  final CgmTrend? trend;

  /// True only for the point merged in directly from the on-demand
  /// LibreLinkUp snapshot's `current` (see [_GlucoseChartPageState._points]).
  /// It's always drawn connected to the rest of the line in [_segments],
  /// regardless of how large the gap to the previous point is — unlike an
  /// ordinary stale tail of local history, it's confirmed to be the sensor's
  /// actual latest reading, so hiding that connection would make the
  /// current number look orphaned from its own chart.
  final bool isLive;
}

/// A hypothesis marker's computed on-screen position. Always exactly one
/// hypothesis per layout \u2014 overlapping markers are never merged into a
/// shared icon+badge anymore; a resolved/corrected one always stays its
/// own free-standing icon, and overlapping pending ones are physically
/// stacked instead (see `_GlucoseChartPageState._stackOverlappingPending`).
/// `hypotheses` stays a list (rather than a single field) only so
/// `_buildEffectWindowBars`'s shared iteration code didn't need to change.
class _HypothesisLayout {
  const _HypothesisLayout({
    required this.hypotheses,
    required this.left,
    required this.top,
  });

  final List<EventHypothesis> hypotheses;
  final double left;
  final double top;
}

/// Sensor readings below/above these bounds are parsing glitches or sensor
/// noise, not real physiology \u2014 never plotted.
const double _minPlausibleMgdl = 20;
const double _maxPlausibleMgdl = 600;

/// A reading timestamped further into the future than this is never real
/// physiology \u2014 it's a clock-skew or timezone-parsing artifact (e.g. a
/// past bug that stored LibreLinkUp's UTC timestamp as if it were already
/// local). Dropped instead of plotted, and self-heals any such rows still
/// sitting in local storage from before that bug was fixed.
const Duration _futureTolerance = Duration(minutes: 2);

/// Two readings logged within this many minutes of each other are treated
/// as the same instant (averaged) so the chart never has more than one
/// y-value for a given x \u2014 it must render a proper function.
const int _sameInstantMinutes = 1;

/// A visual break is drawn whenever consecutive readings are further apart
/// than this, instead of interpolating a line across a sensor gap.
const Duration _maxGapForLine = Duration(minutes: 20);

/// Forward horizons (minutes from "now") plotted as a dashed forecast line
/// extending past the last real reading \u2014 a simple constant-velocity
/// extrapolation from the Kalman filter's own current state, not a new
/// model. See [_GlucoseChartPageState._forecastSpots]. Matches
/// [_futureHorizonOptions] so the chart always has room for all four
/// prediction offsets shown along the "AGORA" line.
const List<double> _forecastHorizonsMinutes = [5, 10, 15, 30];

/// Cycle of minutes-ahead offered by the FUTURO reading column (request
/// #7) — tapping it advances circularly through this list.
const List<double> _futureHorizonOptions = [5, 10, 15, 30];

/// Selectable time-range filters for the chart.
const List<Duration> _windowOptions = [
  Duration(hours: 8),
  Duration(hours: 12),
  Duration(hours: 24),
  Duration(days: 3),
  Duration(days: 7),
];

String _windowLabel(Duration d) =>
    d.inHours % 24 == 0 && d.inDays >= 1 ? '${d.inDays}d' : '${d.inHours}h';

/// Read-only view over the same local event log used everywhere else in
/// the app (manual entries and CGM auto-sync alike) \u2014 a first version of
/// the roadmap chart mentioned in glucose.mmd/cgm.mmd. It never computes
/// or recommends anything; it only plots stored `glucose` events for a
/// selectable, rolling time window ending now.
class GlucoseChartPage extends StatefulWidget {
  const GlucoseChartPage({
    super.key,
    required this.database,
    required this.cgmSyncEngine,
    required this.chatOverlay,
    required this.chatExpanded,
    required this.isOnboarding,
    required this.onOpenChat,
    required this.onHypothesisTap,
    this.onShowDiagnostics,
    this.onInitModel,
    this.onClearConversation,
    this.onSignOut,
    this.hasChatMessages,
  });

  final LocalDatabase database;

  /// The app's single shared CGM background poller — reused here only to
  /// fetch a richer on-demand [LibreLinkUpSnapshot] (target range, sensor,
  /// trend/color), never to duplicate its own reading sync.
  final CgmSyncEngine cgmSyncEngine;

  /// The embedded Nuno chat panel (kept permanently mounted so its model
  /// bootstrap/state survives being shown and hidden), slid up over this
  /// page's content — everything below the "GLICEMIA ATUAL" header — when
  /// [chatExpanded] is true. This page never navigates to a separate chat
  /// screen anymore; Glicemia is the app's home.
  final Widget chatOverlay;

  /// Whether the chat overlay is currently slid into view.
  final bool chatExpanded;

  /// True only while first-run onboarding is still collecting the profile
  /// — the chat then takes over the entire screen (no app bar, no glucose
  /// header) instead of the normal layout's partial overlay, since there is
  /// no real glucose data to show yet at that point. See [_HomeShellState].
  final bool isOnboarding;

  /// Requests that the parent expand the chat overlay, handing back the
  /// deterministic assessment text so it can be surfaced as Nuno's first
  /// message in the conversation.
  final void Function(String report) onOpenChat;

  /// Called when the user taps a Past Event Interpreter timeline marker
  /// — the Timeline's own job ends here; it's the parent's/Nuno's job to
  /// turn the tap into a conversation (Sim/Corrigir/Ignorar), never this
  /// widget's. See docs/fsm/past_event_interpreter.mmd.
  final void Function(EventHypothesis hypothesis) onHypothesisTap;

  // The next 5 callbacks relocated here from a former popup menu on
  // Nuno's own app bar, which was decluttered down to just the
  // avatar/status/collapse button — this menu is now their only home.
  final VoidCallback? onShowDiagnostics;
  final VoidCallback? onInitModel;
  final VoidCallback? onClearConversation;
  final VoidCallback? onSignOut;
  final bool Function()? hasChatMessages;

  @override
  State<GlucoseChartPage> createState() => _GlucoseChartPageState();
}

class _GlucoseChartPageState extends State<GlucoseChartPage> {
  bool _loading = true;
  List<_GlucosePoint> _rawPoints = const [];
  DateTime _asOf = DateTime.now();
  Duration _window = _windowOptions.first;
  String _sourceFilter = 'all'; // 'all' | 'manual' | 'cgm'

  /// Set while the user is pressing/dragging on the chart, so the row above
  /// it can show that spot's value instead of the default floating tooltip.
  FlSpot? _touchedSpot;

  LibreLinkUpSnapshot? _snapshot;
  bool _syncingSnapshot = false;
  Timer? _refreshTimer;

  /// Pending hypotheses for the currently visible window, as persisted by
  /// [HypothesisGateway.hypothesesInWindow] — recomputed by
  /// [_refreshHypotheses] every time the chart's own data reloads. This
  /// state only feeds the tappable markers in [_buildHypothesisMarkers];
  /// it never drives glucose plotting itself.
  List<EventHypothesis> _hypotheses = const [];

  /// See [_MarkerVisibility]. Loaded from [SharedPreferences] in [initState].
  _MarkerVisibility _markerVisibility = _MarkerVisibility.opaque;

  /// Minutes-ahead currently shown by the FUTURO reading column, beyond
  /// what ATUAL already compensates (see [_forecastEstimate]). Cycles
  /// through [_futureHorizonOptions] on tap, circularly.
  double _futureHorizonMinutes = _futureHorizonOptions.first;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshSnapshot();
    _loadMarkerVisibilityPreference();
    // Reloads local data *and* re-fetches the API snapshot every minute, so
    // the time axis and the current reading never go stale between visits.
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) => _refreshAll());
  }

  Future<void> _loadMarkerVisibilityPreference() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(_markerVisibilityPrefsKey);
    final match = _MarkerVisibility.values.where((v) => v.name == stored);
    if (match.isEmpty || !mounted) return;
    setState(() => _markerVisibility = match.first);
  }

  Future<void> _cycleMarkerVisibility() async {
    final next = _MarkerVisibility
        .values[(_markerVisibility.index + 1) % _MarkerVisibility.values.length];
    setState(() => _markerVisibility = next);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_markerVisibilityPrefsKey, next.name);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Fetches the full LibreLinkUp snapshot (target range, sensor, trend)
  /// in the background, showing [_syncingSnapshot] only while in flight.
  Future<void> _refreshSnapshot() async {
    if (_syncingSnapshot) return;
    setState(() => _syncingSnapshot = true);
    try {
      final snapshot = await widget.cgmSyncEngine.fetchFullSnapshotOnce();
      if (!mounted) return;
      if (snapshot != null) setState(() => _snapshot = snapshot);
    } catch (_) {
      // Best-effort: a transient failure just keeps the last known snapshot.
    } finally {
      if (mounted) setState(() => _syncingSnapshot = false);
    }
  }

  /// Backs the pull-to-refresh gesture: reloads local events and re-fetches
  /// the API snapshot together, on top of the once-a-minute timer above.
  Future<void> _refreshAll() => Future.wait([_load(silent: true), _refreshSnapshot()]);

  /// [silent] skips the full-screen spinner — used by pull-to-refresh and
  /// the periodic timer, which show the floating sync pill instead.
  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final asOf = DateTime.now();
    // Purges any row still carrying a fake-future timestamp from the fixed
    // UTC-parsing bug before it can be read back as "current"/plotted again.
    await widget.database.deleteFutureGlucoseReadings(tolerance: _futureTolerance);
    final rows = await widget.database.recentEventsOfType('glucose', _window);
    final futureCutoff = asOf.add(_futureTolerance);
    final raw = <_GlucosePoint>[];
    for (final row in rows) {
      try {
        final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        final value = payload['value'];
        if (value is! num) continue;
        final mgdl = value.toDouble();
        if (mgdl < _minPlausibleMgdl || mgdl > _maxPlausibleMgdl) continue;
        final at = DateTime.parse(row['created_at'] as String);
        if (at.isAfter(futureCutoff)) continue;
        final source = payload['measurementContext'] == 'cgm' ? 'cgm' : 'manual';
        final trend = cgmTrendFromLabel(payload['trend'] as String?);
        raw.add(_GlucosePoint(at, mgdl, source, trend: trend));
      } catch (_) {
        // Skip malformed rows rather than failing the whole chart.
      }
    }
    if (!mounted) return;
    setState(() {
      _rawPoints = raw;
      _asOf = asOf;
      _loading = false;
    });
    await _refreshHypotheses();
  }

  /// Re-runs [PastEventInterpreter.analyze] over the chart's own sensor
  /// series plus already-logged meal/insulin/exercise events in the same
  /// window, persists any new/ongoing hypotheses (existing ones the user
  /// already resolved are left untouched — see
  /// [HypothesisGateway.refreshPendingHypothesis]), then reloads the
  /// visible window from storage so [_hypotheses] always reflects the
  /// user's own confirm/correct/dismiss decisions, not just this run's
  /// fresh analysis. This method only observes/interprets and persists;
  /// it never opens the Nuno conversation itself — see
  /// docs/fsm/past_event_interpreter.mmd.
  Future<void> _refreshHypotheses() async {
    final points = _points;
    if (points.length < 2) {
      if (mounted) {
        setState(() => _hypotheses = const []);
      }
      return;
    }
    final estimates = _estimateSeries(points, includeTrend: false);
    final samples = [
      for (final p in points) GlucoseSample(at: p.at, mgdl: p.mgdl),
    ];
    final knownEvents = <KnownContextEvent>[];
    const knownEventTypes = {
      'meal': HypothesisType.meal,
      'insulin': HypothesisType.insulin,
      'exercise': HypothesisType.exercise,
    };
    for (final entry in knownEventTypes.entries) {
      final rows = await widget.database.recentEventsOfType(entry.key, _window);
      for (final row in rows) {
        try {
          knownEvents.add(KnownContextEvent(
            type: entry.value,
            at: DateTime.parse(row['created_at'] as String),
          ));
        } catch (_) {
          // Skip malformed rows rather than failing hypothesis analysis.
        }
      }
    }
    final fresh = const PastEventInterpreter().analyze(
      samples: samples,
      estimates: estimates,
      knownEvents: knownEvents,
    );
    for (final hypothesis in fresh) {
      // Ongoing threads (see PastEventInterpreter._dedupe) refresh their
      // existing pending row in place; only a brand-new thread — or one
      // whose row is already resolved, where the refresh is a deliberate
      // no-op — falls through to the ifAbsent insert.
      final refreshed = await widget.database.refreshPendingHypothesis(hypothesis);
      if (!refreshed) {
        await widget.database.upsertHypothesisIfAbsent(hypothesis);
      }
      // Cleans up stray rows left over from before the same candidates
      // merged into this one thread (or from an older app version).
      await widget.database.prunePendingDuplicates(hypothesis);
    }
    final stored =
        await widget.database.hypothesesInWindow(_windowStart, _effectiveAsOf);
    if (!mounted) return;
    setState(() => _hypotheses = stored);
  }

  /// Readings after the active source filter, collapsed to at most one
  /// averaged value per minute and sorted ascending \u2014 guarantees a
  /// strictly increasing x-axis (a function can't have two y for one x).
  ///
  /// The live snapshot's `current` reading is merged in when it's newer
  /// than anything persisted locally yet, so the big number above the
  /// chart is always exactly the graph's last point, never a separate,
  /// possibly-fresher value from a different fetch.
  List<_GlucosePoint> get _points {
    final filtered = _sourceFilter == 'all'
        ? _rawPoints
        : _rawPoints.where((p) => p.source == _sourceFilter).toList();
    final live = _snapshot?.current;
    final lastLocalAt = filtered.isEmpty
        ? null
        : filtered.map((p) => p.at).reduce((a, b) => a.isAfter(b) ? a : b);
    final liveMerged = live != null &&
        _sourceFilter != 'manual' &&
        !live.timestamp.isAfter(DateTime.now().add(_futureTolerance)) &&
        live.timestamp.isAfter(_windowStart) &&
        (lastLocalAt == null || live.timestamp.isAfter(lastLocalAt));
    final merged = liveMerged
        ? [...filtered, _GlucosePoint(live.timestamp, live.mgdl, 'cgm', trend: live.trend)]
        : filtered;
    final sums = <int, double>{};
    final counts = <int, int>{};
    final trends = <int, CgmTrend>{};
    for (final p in merged) {
      final bucketMs = p.at.millisecondsSinceEpoch ~/
          (_sameInstantMinutes * 60000) *
          (_sameInstantMinutes * 60000);
      sums[bucketMs] = (sums[bucketMs] ?? 0) + p.mgdl;
      counts[bucketMs] = (counts[bucketMs] ?? 0) + 1;
      if (p.trend != null) trends[bucketMs] = p.trend!;
    }
    final result = sums.keys
        .map((ms) => _GlucosePoint(
              DateTime.fromMillisecondsSinceEpoch(ms),
              sums[ms]! / counts[ms]!,
              'mixed',
              trend: trends[ms],
            ))
        .toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    // The live reading's own timestamp is the newest by construction (see
    // the merge condition above), so after sorting it always lands last —
    // mark that bucket as the connect-regardless-of-gap point.
    if (liveMerged && result.isNotEmpty) {
      final last = result.removeLast();
      result.add(_GlucosePoint(last.at, last.mgdl, last.source, isLive: true, trend: last.trend));
    }
    return result;
  }

  static const double _defaultTargetLow = 70;
  static const double _defaultTargetHigh = 180;

  /// The patient's own configured target range when the LibreLinkUp
  /// snapshot has one, falling back to the generic clinical default.
  double get _targetLow => _snapshot?.targets?.targetLow ?? _defaultTargetLow;
  double get _targetHigh => _snapshot?.targets?.targetHigh ?? _defaultTargetHigh;
  bool get _hasPersonalTargets => _snapshot?.targets?.targetLow != null;

  /// [_asOf] is captured when local data loads, but a fresher reading can
  /// already exist by the time this getter runs: the live snapshot resolves
  /// later than `_load()`, and the independent background `CgmSyncEngine`
  /// timer can write a newer local reading between one `_load()` call and
  /// the next. Anchoring the window on whichever of the three is newest
  /// keeps every real data point inside the plotted x-range, instead of
  /// past the right edge where `FlClipData` would hide it \u2014 invisible on
  /// screen even though the current-reading number (the same point) showed
  /// correctly.
  DateTime get _effectiveAsOf {
    var latest = _asOf;
    final liveAt = _snapshot?.current?.timestamp;
    if (liveAt != null && liveAt.isAfter(latest)) latest = liveAt;
    for (final p in _rawPoints) {
      if (p.at.isAfter(latest)) latest = p.at;
    }
    return latest;
  }

  DateTime get _windowStart => _effectiveAsOf.subtract(_window);

  _GlucosePoint? get _current => _points.isEmpty ? null : _points.last;

  /// Each point already carries its own trend, from local storage or the
  /// live snapshot merge (see [_points]) — no source-specific lookup needed.
  CgmTrend? _trendForPoint(_GlucosePoint p) => p.trend;

  /// Runs [points] (already chronological) through a fresh [GlucoseEstimator]
  /// \u2014 recomputed from scratch each call rather than kept as long-lived
  /// state, consistent with how [_points] itself is recomputed on every read
  /// (see its doc comment). Cheap enough for a phone-local chart of at most
  /// a few thousand points.
  // [includeTrend]=false is required for hypothesis analysis: fusing the
  // sensor's own coarse trend arrow into the Kalman velocity state pulls
  // it toward agreeing with the sensor, suppressing the very
  // value/velocity residual PastEventInterpreter looks for.
  List<GlucoseEstimate> _estimateSeries(List<_GlucosePoint> points, {bool includeTrend = true}) {
    final estimator = GlucoseEstimator();
    return [
      for (final p in points)
        estimator.addReading(p.mgdl, p.at, trend: includeTrend ? _trendForPoint(p) : null),
    ];
  }

  /// The Kalman-based physiological estimate for the latest reading \u2014 see
  /// lib/cgm/glucose_estimator.dart. Never replaces [_current]; only ever
  /// shown alongside it.
  GlucoseEstimate? get _latestEstimate {
    final points = _points;
    if (points.isEmpty) return null;
    return _estimateSeries(points).last;
  }

  /// The FUTURO reading's projection: [_futureHorizonMinutes] further
  /// ahead than [_latestEstimate] already compensates (total horizon =
  /// [GlucoseEstimator.lagMinutes] + [_futureHorizonMinutes]) — see
  /// [GlucoseEstimator.forecast]. Null until there's at least one point.
  GlucoseEstimate? get _futureEstimate {
    final points = _points;
    if (points.isEmpty) return null;
    final estimator = GlucoseEstimator();
    for (final p in points) {
      estimator.addReading(p.mgdl, p.at, trend: _trendForPoint(p));
    }
    return estimator.forecast(_futureHorizonMinutes);
  }

  /// Advances [_futureHorizonMinutes] to the next entry in
  /// [_futureHorizonOptions], circularly.
  void _cycleFutureHorizon() {
    final index = _futureHorizonOptions.indexOf(_futureHorizonMinutes);
    final next = _futureHorizonOptions[(index + 1) % _futureHorizonOptions.length];
    setState(() => _futureHorizonMinutes = next);
  }

  /// Dashed continuation of the Kalman line past the last real reading, at
  /// [_forecastHorizonsMinutes] \u2014 pure constant-velocity extrapolation from
  /// [GlucoseEstimate.estimatedNow]/[GlucoseEstimate.velocity] (the same
  /// linear state-transition the filter itself uses in `predict()`), never
  /// a new/independent model. Empty when there isn't yet a reading to
  /// extrapolate from.
  List<FlSpot> _forecastSpots(List<_GlucosePoint> points) {
    if (points.isEmpty) return const [];
    final estimate = _estimateSeries(points).last;
    final anchorAt = points.last.at;
    return [
      FlSpot(_xFor(anchorAt), estimate.estimatedNow),
      for (final minutes in _forecastHorizonsMinutes)
        FlSpot(
          _xFor(anchorAt.add(Duration(minutes: minutes.round()))),
          estimate.estimatedNow + estimate.velocity * minutes,
        ),
    ];
  }

  /// The chart's x-axis upper bound (hours since [_windowStart]) \u2014 shared
  /// by [_buildChartData] (so fl_chart's own scale matches this) and
  /// [_buildHypothesisMarkers] (so a marker's horizontal position lines up
  /// with the sensor point it explains), instead of two independent
  /// computations silently drifting apart.
  ///
  /// Reserves [_forecastZoneFraction] of the total width for the AGORA/
  /// forecast zone past "now", so that zone never gets squeezed down to a
  /// sliver even when the +5/10/15/30 min forecast spots themselves would
  /// fit in less space (request #4).
  static const double _forecastZoneFraction = 0.16;

  double _chartMaxX(List<_GlucosePoint> points) {
    final forecastSpots = _forecastSpots(points);
    final windowHours = _window.inHours.toDouble();
    final reservedMaxX = windowHours / (1 - _forecastZoneFraction);
    final forecastMaxX =
        forecastSpots.isEmpty ? windowHours : forecastSpots.map((s) => s.x).reduce(math.max);
    return math.max(reservedMaxX, forecastMaxX);
  }

  /// Colored, type-specific icon shown only once a hypothesis has been
  /// resolved ([HypothesisStatus.confirmed] or [HypothesisStatus.corrected])
  /// \u2014 while still [HypothesisStatus.pending] (or dismissed), the marker
  /// shows a neutral question mark instead (see [_buildHypothesisMarkers]),
  /// since the type is only a guess until the user validates or corrects it.
  static const Map<HypothesisType, IconData> _hypothesisIcon = {
    HypothesisType.meal: Icons.restaurant,
    HypothesisType.insulin: Icons.vaccines,
    HypothesisType.exercise: Icons.directions_run,
    HypothesisType.dawnPhenomenon: Icons.wb_twilight,
    HypothesisType.stress: Icons.sentiment_very_dissatisfied,
  };

  static const Map<HypothesisType, Color> _hypothesisColor = {
    HypothesisType.meal: Color(0xFFEF8A3D),
    HypothesisType.insulin: Color(0xFF3D8AEF),
    HypothesisType.exercise: Color(0xFF3DAE55),
    HypothesisType.dawnPhenomenon: Color(0xFFE0C23D),
    HypothesisType.stress: Color(0xFFE0475D),
  };

  /// Reserved size (logical px) fl_chart carves out of the left axis for
  /// tick labels in [_buildChartData]'s `leftTitles` \u2014 kept in sync with
  /// that value so markers align with the plotted data instead of an axis
  /// label.
  static const double _chartLeftAxisReservedWidth = 36;

  /// Marker circle diameter \u2014 larger than the emoji-text markers this
  /// replaced, per request, so both the pending question-mark and the
  /// resolved type icon are easier to tap and read.
  static const double _hypothesisMarkerSize = 34;

  /// Assigns each hypothesis its natural (unclustered) marker position \u2014
  /// horizontally at [EventHypothesis.estimatedPeak], vertically just above
  /// the glucose curve's own value at that time.
  ///
  /// Kept below [_topLabelClearance] so a marker near "now" never paints
  /// over fl_chart's own AGORA/forecast-horizon labels at the chart's top.
  static const double _topLabelClearance = 26.0;

  List<_HypothesisLayout> _layoutHypotheses(
    List<_GlucosePoint> points,
    double maxX,
    double plotWidth,
    double plotHeight,
    ({double minY, double maxY}) yRange,
  ) {
    const plotLeft = _chartLeftAxisReservedWidth;
    const markerGapAboveCurve = 8.0;
    final layouts = <_HypothesisLayout>[];
    for (final hypothesis in _hypotheses) {
      // A confirmed/corrected hypothesis anchors its marker on the causal
      // event's own start time instead of the peak, so the icon sits where
      // the meal/insulin/exercise actually happened (request #3).
      final isResolved = hypothesis.status == HypothesisStatus.confirmed ||
          hypothesis.status == HypothesisStatus.corrected;
      final anchor = isResolved ? hypothesis.estimatedStart : hypothesis.estimatedPeak;
      final x = _xFor(anchor);
      if (x < 0 || x > maxX) continue;
      final fraction = x / maxX;
      final left = plotLeft + fraction * plotWidth - _hypothesisMarkerSize / 2;
      final curveValue = _nearestPoint(points, anchor)?.mgdl;
      double top;
      if (curveValue == null || yRange.maxY <= yRange.minY) {
        top = _topLabelClearance;
      } else {
        final valueFraction =
            ((yRange.maxY - curveValue) / (yRange.maxY - yRange.minY)).clamp(0.0, 1.0);
        final curveTop = valueFraction * plotHeight;
        top = (curveTop - _hypothesisMarkerSize - markerGapAboveCurve).clamp(
          _topLabelClearance,
          math.max(_topLabelClearance, plotHeight - _hypothesisMarkerSize),
        );
      }
      layouts.add(_HypothesisLayout(hypotheses: [hypothesis], left: left, top: top));
    }
    return layouts;
  }

  /// Overlapping *pending* markers are physically stacked above or below
  /// the curve instead of merged into one icon with a count badge (a
  /// resolved/corrected hypothesis is never part of this \u2014 see
  /// [_buildHypothesisMarkers], which never even passes resolved layouts
  /// in here). Within a horizontally-overlapping cluster, whichever
  /// member has the LOWER glucose value at its own anchor keeps its
  /// natural above-the-curve slot (plenty of headroom above a low point);
  /// the other(s) flip to a below-the-curve slot instead (headroom below,
  /// avoiding the AGORA/forecast labels near the chart's top). Since
  /// "lower curve value" is exactly what a before/after position implies
  /// once the local rise/fall direction is known, this expresses that
  /// same before-or-after-and-rising-or-falling relationship directly via
  /// the curve's own value instead of re-deriving it from time order and
  /// slope sign. More than two members on the same side stack further
  /// out from the curve, one [_hypothesisMarkerSize] apart.
  List<_HypothesisLayout> _stackOverlappingPending(
    List<_HypothesisLayout> layouts,
    List<_GlucosePoint> points,
    ({double minY, double maxY}) yRange,
    double plotHeight,
  ) {
    const markerGapBelowCurve = 8.0;
    const stackSpacing = _hypothesisMarkerSize + 6.0;
    final sorted = [...layouts]..sort((a, b) => a.left.compareTo(b.left));
    final clusters = <List<_HypothesisLayout>>[];
    for (final layout in sorted) {
      if (clusters.isNotEmpty &&
          (layout.left - clusters.last.last.left).abs() < _hypothesisMarkerSize) {
        clusters.last.add(layout);
      } else {
        clusters.add([layout]);
      }
    }
    final result = <_HypothesisLayout>[];
    for (final cluster in clusters) {
      if (cluster.length == 1) {
        result.add(cluster.single);
        continue;
      }
      final withValue = [
        for (final layout in cluster)
          (
            layout: layout,
            mgdl: _nearestPoint(points, layout.hypotheses.single.estimatedPeak)?.mgdl ?? 0.0,
          ),
      ]..sort((a, b) => a.mgdl.compareTo(b.mgdl));
      final aboveCount = (withValue.length / 2).ceil();
      final canPositionOnCurve = yRange.maxY > yRange.minY;
      for (var i = 0; i < withValue.length; i++) {
        final entry = withValue[i];
        if (i < aboveCount) {
          final top = (entry.layout.top - i * stackSpacing).clamp(
            _topLabelClearance,
            math.max(_topLabelClearance, plotHeight - _hypothesisMarkerSize),
          );
          result.add(_HypothesisLayout(
            hypotheses: entry.layout.hypotheses,
            left: entry.layout.left,
            top: top.toDouble(),
          ));
        } else {
          final belowIndex = i - aboveCount;
          double top;
          if (!canPositionOnCurve) {
            top = _topLabelClearance + belowIndex * stackSpacing;
          } else {
            final valueFraction =
                ((yRange.maxY - entry.mgdl) / (yRange.maxY - yRange.minY)).clamp(0.0, 1.0);
            final curveTop = valueFraction * plotHeight;
            top = curveTop + markerGapBelowCurve + belowIndex * stackSpacing;
          }
          top = top.clamp(0.0, math.max(0.0, plotHeight - _hypothesisMarkerSize));
          result.add(_HypothesisLayout(
            hypotheses: entry.layout.hypotheses,
            left: entry.layout.left,
            top: top.toDouble(),
          ));
        }
      }
    }
    return result;
  }

  /// Non-intrusive tappable markers for [_hypotheses], one per hypothesis,
  /// positioned at the x matching [EventHypothesis.estimatedPeak] and just
  /// above the glucose curve's own value at that time (instead of a fixed
  /// height near the top of the chart). Only the Timeline's own concern
  /// (layout/positioning/icon-state) lives here \u2014 tapping just reports
  /// the tap to the parent via [GlucoseChartPage.onHypothesisTap], which
  /// owns turning it into a Nuno conversation.
  /// See docs/fsm/past_event_interpreter.mmd.
  Widget _buildHypothesisMarkers(List<_GlucosePoint> points) {
    if (_hypotheses.isEmpty) return const SizedBox.shrink();
    if (_markerVisibility == _MarkerVisibility.hidden) return const SizedBox.shrink();
    final maxX = _chartMaxX(points);
    if (maxX <= 0) return const SizedBox.shrink();
    final yRange = _yRange(points);
    final bottomReserved = _window.inHours > 24 ? 36.0 : 28.0;
    final markersOpacity =
        _markerVisibility == _MarkerVisibility.translucent ? 0.35 : 1.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        const plotLeft = _chartLeftAxisReservedWidth;
        final plotWidth = (constraints.maxWidth - plotLeft).clamp(0, constraints.maxWidth);
        final plotHeight =
            (constraints.maxHeight - bottomReserved).clamp(0.0, constraints.maxHeight);
        final natural =
            _layoutHypotheses(points, maxX, plotWidth.toDouble(), plotHeight, yRange);
        // A resolved/corrected hypothesis always gets its own free-standing
        // icon, never merged or stacked with anything else — only the
        // still-pending ones (which render as a neutral "?") get stacked
        // when they overlap in time.
        final resolved = <_HypothesisLayout>[];
        final pending = <_HypothesisLayout>[];
        for (final layout in natural) {
          final isResolved = layout.hypotheses.single.status == HypothesisStatus.confirmed ||
              layout.hypotheses.single.status == HypothesisStatus.corrected;
          (isResolved ? resolved : pending).add(layout);
        }
        final layouts = [
          ...resolved,
          ..._stackOverlappingPending(pending, points, yRange, plotHeight),
        ];
        return Stack(
          children: [
            // Duration-of-effect bars only ever show in opaque mode (never
            // translucent, which shows icons only, nor hidden) \u2014 kept
            // outside the icons' own Opacity wrapper below so translucent
            // mode can't partially reveal them, per request #4.
            if (_markerVisibility == _MarkerVisibility.opaque)
              ..._buildEffectWindowBars(layouts, maxX, plotWidth.toDouble(), plotHeight),
            Opacity(
              opacity: markersOpacity,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final layout in layouts)
                    Builder(builder: (context) {
                      final hypothesis = layout.hypotheses.single;
                      final isResolved = hypothesis.status == HypothesisStatus.confirmed ||
                          hypothesis.status == HypothesisStatus.corrected;
                      final isDismissed = hypothesis.status == HypothesisStatus.dismissed;
                      final icon = isResolved
                          ? (_hypothesisIcon[hypothesis.type] ?? Icons.help_outline)
                          : Icons.help_outline;
                      final iconColor = isResolved
                          ? (_hypothesisColor[hypothesis.type] ?? DiabAIPalette.accent)
                          : DiabAIPalette.accent;

                      return Positioned(
                        left: layout.left.clamp(0, constraints.maxWidth - _hypothesisMarkerSize).toDouble(),
                        top: layout.top,
                        child: GestureDetector(
                          onTap: () => widget.onHypothesisTap(hypothesis),
                          child: Opacity(
                            opacity: isDismissed ? 0.45 : 1.0,
                            child: Container(
                              width: _hypothesisMarkerSize,
                              height: _hypothesisMarkerSize,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: DiabAIPalette.surface,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isResolved ? iconColor : DiabAIPalette.surfaceBorder,
                                  width: isResolved ? 1.5 : 1,
                                ),
                              ),
                              child: Icon(icon, size: 20, color: iconColor),
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Thin, semi-transparent "still acting" bars for resolved hypotheses of
  /// any type \u2014 spanning [EventHypothesis.estimatedStart] to
  /// [EventHypothesis.effectWindowEnd], centered vertically on the
  /// hypothesis's own marker so the line reads as coming out of the icon
  /// (request #3). Opaque-mode-only, per request #4 (translucent shows
  /// icons only, hidden shows nothing).
  List<Widget> _buildEffectWindowBars(
    List<_HypothesisLayout> layouts,
    double maxX,
    double plotWidth,
    double plotHeight,
  ) {
    const plotLeft = _chartLeftAxisReservedWidth;
    // Matches the resolved marker's own border exactly (see
    // _buildHypothesisMarkers's `allResolved && sameType` case) — full
    // opacity, same width — so the line reads as a literal extension of
    // the icon's outline, not a separate decoration.
    const barHeight = 1.5;
    final bars = <Widget>[];
    for (final layout in layouts) {
      for (final hypothesis in layout.hypotheses) {
        final isResolved = hypothesis.status == HypothesisStatus.confirmed ||
            hypothesis.status == HypothesisStatus.corrected;
        if (!isResolved) continue;
        final startX = _xFor(hypothesis.estimatedStart).clamp(0.0, maxX);
        final endX = _xFor(hypothesis.effectWindowEnd).clamp(0.0, maxX);
        if (endX <= startX) continue;
        final left = plotLeft + (startX / maxX) * plotWidth;
        final width = (endX - startX) / maxX * plotWidth;
        final top = (layout.top + _hypothesisMarkerSize / 2 - barHeight / 2)
            .clamp(0.0, math.max(0.0, plotHeight - barHeight))
            .toDouble();
        final color = _hypothesisColor[hypothesis.type] ?? DiabAIPalette.accent;
        bars.add(Positioned(
          left: left,
          top: top,
          width: width,
          height: barHeight,
          child: IgnorePointer(
            child: Container(color: color),
          ),
        ));
      }
    }
    return bars;
  }

  /// Small floating control that cycles [_markerVisibility] \u2014 kept right
  /// on top of the chart (per request #4), not in the [_ChartMenuAction]
  /// app-bar menu, since it's a display toggle for the chart's own
  /// hypothesis markers rather than a data/account action.
  Widget _buildMarkerVisibilityToggle() {
    late final IconData icon;
    late final double iconOpacity;
    late final String tooltip;
    switch (_markerVisibility) {
      case _MarkerVisibility.opaque:
        icon = Icons.circle;
        iconOpacity = 1.0;
        tooltip = 'Marcadores opacos \u2014 toque para deixar semitransparentes';
        break;
      case _MarkerVisibility.translucent:
        icon = Icons.circle;
        iconOpacity = 0.35;
        tooltip = 'Marcadores semitransparentes \u2014 toque para ocultar';
        break;
      case _MarkerVisibility.hidden:
        icon = Icons.visibility_off;
        iconOpacity = 1.0;
        tooltip = 'Marcadores ocultos \u2014 toque para exibir';
        break;
    }
    return Material(
      color: DiabAIPalette.surface,
      shape: const CircleBorder(),
      elevation: 1,
      child: IconButton(
        tooltip: tooltip,
        onPressed: _cycleMarkerVisibility,
        icon: Opacity(
          opacity: iconOpacity,
          child: Icon(icon, size: 18, color: DiabAIPalette.accent),
        ),
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: EdgeInsets.zero,
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    // First-run onboarding has no real glucose data to show yet \u2014 the chat
    // takes over the whole screen instead of the normal partial overlay
    // (which would otherwise leave the app bar/header showing stale or
    // unrelated data above it).
    if (widget.isOnboarding) {
      return Scaffold(body: SafeArea(child: widget.chatOverlay));
    }
    final points = _points;
    return Scaffold(
      // A left-to-right side menu (its real content is a follow-up task);
      // setting `drawer` makes Flutter show the standard hamburger icon
      // where the "Glicemia — últimas Xh" title used to be, replacing it.
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: const [
              DrawerHeader(child: Text('DiabAI')),
              ListTile(
                leading: Icon(Icons.construction_outlined),
                title: Text('Menu em construção'),
              ),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Ver perfil',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProfileViewPage(
                profileEngine: ProfileEngine(
                  snapshotGateway: LocalDatabase.instance,
                ),
              ),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Configurações de glicemia',
            onPressed: _openSettings,
          ),
          PopupMenuButton<_ChartMenuAction>(
            icon: const Icon(Icons.more_vert),
            onSelected: (action) {
              switch (action) {
                case _ChartMenuAction.clearDebugData:
                  _clearDebugData();
                case _ChartMenuAction.diagnostics:
                  widget.onShowDiagnostics?.call();
                case _ChartMenuAction.initModel:
                  widget.onInitModel?.call();
                case _ChartMenuAction.clearConversation:
                  widget.onClearConversation?.call();
                case _ChartMenuAction.signOut:
                  widget.onSignOut?.call();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _ChartMenuAction.clearDebugData,
                child: ListTile(
                  leading: Icon(Icons.delete_forever_outlined),
                  title: Text('Apagar dados'),
                ),
              ),
              if (kDebugMode)
                const PopupMenuItem(
                  value: _ChartMenuAction.diagnostics,
                  child: ListTile(
                    leading: Icon(Icons.bug_report_outlined),
                    title: Text('Diagnóstico da interpretação'),
                  ),
                ),
              const PopupMenuItem(
                value: _ChartMenuAction.initModel,
                child: ListTile(
                  leading: Icon(Icons.cloud_download_outlined),
                  title: Text('Inicializar modelo local'),
                ),
              ),
              PopupMenuItem(
                value: _ChartMenuAction.clearConversation,
                enabled: widget.hasChatMessages?.call() ?? false,
                child: const ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Limpar conversa'),
                ),
              ),
              const PopupMenuItem(
                value: _ChartMenuAction.signOut,
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Sair'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: [
                  // Pinned above the chat overlay at all times, per the
                  // requested layout: only "GLICEMIA ATUAL" + value/unit
                  // stays visible once the conversation slides up.
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Center(child: _buildCurrentReading(context)),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        Column(
                          children: [
                            Expanded(
                              child: RefreshIndicator(
                                onRefresh: _refreshAll,
                                child: SingleChildScrollView(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 16, 20, 12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (points.isEmpty)
                                        const Padding(
                                          padding:
                                              EdgeInsets.symmetric(vertical: 24),
                                          child: Text(
                                            'Nenhuma leitura de glicemia registrada nesse período/filtro. '
                                            'Registre uma glicemia ou conecte um CGM no seu perfil.',
                                            textAlign: TextAlign.center,
                                          ),
                                        )
                                      else ...[
                                        SizedBox(
                                          height:
                                              MediaQuery.sizeOf(context).height *
                                                  0.4,
                                          child: Stack(
                                            children: [
                                              LineChart(_buildChartData(context)),
                                              Positioned.fill(
                                                child: _buildHypothesisMarkers(points),
                                              ),
                                              if (_hypotheses.isNotEmpty)
                                                Positioned(
                                                  // Cleared above the bottom
                                                  // axis's own reserved band,
                                                  // and right of the left
                                                  // (mg/dL) axis's own
                                                  // reserved column, so it
                                                  // never sits on top of
                                                  // either axis's labels.
                                                  bottom: (_window.inHours > 24 ? 36.0 : 28.0) + 6,
                                                  left: _chartLeftAxisReservedWidth + 4,
                                                  child: _buildMarkerVisibilityToggle(),
                                                ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        _buildLegend(context),
                                        const SizedBox(height: 12),
                                        _buildNunoAssessment(context),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            _buildReportRequest(context),
                          ],
                        ),
                        _buildSyncOverlay(context),
                        _buildChatOverlay(context),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// The Nuno conversation, slid up from the bottom to cover everything
  /// below the pinned "GLICEMIA ATUAL" header (chart, legend, assessment
  /// card, and the "Conversar com Nuno" button) when [chatExpanded] is
  /// true. The panel itself stays mounted at all times (its position is
  /// only animated) so the model/session state inside it is never lost.
  Widget _buildChatOverlay(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !widget.chatExpanded,
        child: AnimatedSlide(
          offset: widget.chatExpanded ? Offset.zero : const Offset(0, 1),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
          child: widget.chatOverlay,
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GlucoseSettingsPage(
        window: _window,
        sourceFilter: _sourceFilter,
        onWindowChanged: (w) {
          setState(() => _window = w);
          // A wider/narrower window changes _windowStart, so the live
          // snapshot must be re-fetched too — otherwise this path would show
          // an older current reading than the periodic refresh does.
          _refreshAll();
        },
        onSourceFilterChanged: (s) => setState(() => _sourceFilter = s),
      ),
    ));
  }

  Future<void> _clearDebugData() async {
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Apagar dados?'),
        content: const Text(
          'Isso apaga perfil, eventos, auditoria, conexão com o CGM e sessão '
          'local deste dispositivo. Você precisará refazer a inicialização.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_forever),
            label: const Text('Apagar'),
          ),
        ],
      ),
    );
    if (shouldClear != true) return;

    await LocalDatabase.instance.clearAll();
    final preferences = await SharedPreferences.getInstance();
    await preferences.clear();
    // The LibreLinkUp session lives in secure storage, untouched by the
    // above — without this, a stale CGM connection survives this "wipe"
    // and keeps showing old readings.
    await LibreLinkUpCredentialStore().clear();
    await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Dados apagados. Feche e abra o app novamente.'),
      ));
    }
  }

  /// Floats over the content instead of taking a line in the layout \u2014
  /// fades in/out with [_syncingSnapshot] rather than popping in and out.
  Widget _buildSyncOverlay(BuildContext context) {
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: Center(
        child: IgnorePointer(
          ignoring: !_syncingSnapshot,
          child: AnimatedOpacity(
            opacity: _syncingSnapshot ? 1 : 0,
            duration: const Duration(milliseconds: 1800),
            curve: Curves.easeOut,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: DiabAIPalette.surface.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: DiabAIPalette.surfaceBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: DiabAIPalette.iconMuted),
                  ),
                  SizedBox(width: 8),
                  Text('Atualizando dados...',
                      style: TextStyle(fontSize: 11, color: DiabAIPalette.iconMuted)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The API's own trend arrow, quantized to 5 fixed positions (45\u00b0 apart)
  /// \u2014 straight down/up for the "quickly" buckets, diagonal for a plain
  /// rise/fall, flat right for stable. Base icon points right (0\u00b0/stable).
  double? _sensorTrendAngleDegrees(CgmTrend? trend) {
    switch (trend) {
      case CgmTrend.fallingQuickly:
        return 90;
      case CgmTrend.falling:
        return 45;
      case CgmTrend.stable:
        return 0;
      case CgmTrend.rising:
        return -45;
      case CgmTrend.risingQuickly:
        return -90;
      case null:
        return null;
    }
  }

  /// Same up/flat/down convention as [_sensorTrendAngleDegrees], but driven
  /// continuously by the Kalman filter's own velocity state and snapped to
  /// 22.5\u00b0 steps \u2014 double the sensor arrow's resolution, since the filter
  /// isn't limited to 5 discrete API buckets.
  double? _kalmanTrendAngleDegrees(double? velocity) {
    if (velocity == null) return null;
    const degreesPerMgdlPerMin = 90 / 3.5;
    const step = 22.5;
    final raw = (-velocity * degreesPerMgdlPerMin).clamp(-90.0, 90.0);
    return (raw / step).round() * step;
  }

  Widget _buildCurrentReading(BuildContext context) {
    final current = _current;
    final estimate = _latestEstimate;
    final future = _futureEstimate;

    final sensorColumn = _buildReadingColumn(
      label: 'SENSOR',
      value: current?.mgdl,
      trendAngleDegrees:
          current == null ? null : _sensorTrendAngleDegrees(_trendForPoint(current)),
    );

    // Confidence/lag caption lives only on FUTURO now — ATUAL is what the
    // system treats as the current glucose, trusted enough to show plain.
    final estimateColumn = _buildReadingColumn(
      label: 'ATUAL',
      value: estimate?.estimatedNow,
      trendAngleDegrees: estimate == null ? null : _kalmanTrendAngleDegrees(estimate.velocity),
    );

    final futureColumn = _buildReadingColumn(
      label: 'FUTURO',
      value: future?.estimatedNow,
      caption: future == null
          ? null
          : '${_confidenceEmoji(future.confidencePercent)} '
              '${future.confidencePercent.round()}% · '
              '+${_futureHorizonMinutes.round()} min',
      onTap: future == null ? null : _cycleFutureHorizon,
    );

    // Equal-flex thirds (not a shrink-wrapped row) so ATUAL always lands
    // exactly in the screen's visual center, regardless of how wide SENSOR
    // or FUTURO's own content happens to be.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Center(child: sensorColumn)),
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Container(width: 1, height: 60, color: DiabAIPalette.surfaceBorder),
        ),
        Expanded(child: Center(child: estimateColumn)),
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Container(width: 1, height: 60, color: DiabAIPalette.surfaceBorder),
        ),
        Expanded(child: Center(child: futureColumn)),
      ],
    );
  }

  /// One "SENSOR"/"ATUAL"/"FUTURO" reading block — always shown at equal
  /// visual weight, never one hidden behind or promoted over the others,
  /// per spec: the raw sensor value and the Kalman estimates are both real
  /// information the user is entitled to see, all the time. Shows a '-'
  /// placeholder (never a fabricated number) until a real [value] has been
  /// obtained. [onTap], when set (FUTURO only), cycles the shown horizon.
  static const double _trendIconSlotWidth = 28;

  Widget _buildReadingColumn({
    required String label,
    required double? value,
    double? trendAngleDegrees,
    VoidCallback? onTap,
    String? caption,
  }) {
    final inRange = value != null && value >= _targetLow && value <= _targetHigh;
    final color = value == null
        ? DiabAIPalette.iconMuted
        : (inRange ? DiabAIPalette.online : DiabAIPalette.offline);
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: DiabAIPalette.iconMuted,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // A mirrored, equal-width invisible spacer on the left keeps
            // the number itself centered in the column even though the
            // arrow (right-only) would otherwise pull it visually left.
            if (trendAngleDegrees != null) const SizedBox(width: _trendIconSlotWidth),
            Text(
              value == null ? '-' : value.round().toString(),
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                color: color,
                height: 1,
              ),
            ),
            if (trendAngleDegrees != null)
              SizedBox(
                width: _trendIconSlotWidth,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Transform.rotate(
                    angle: trendAngleDegrees * math.pi / 180,
                    child: Icon(Icons.arrow_forward, size: 24, color: color),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        const Text(
          'mg/dL',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: DiabAIPalette.textSecondary,
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 4),
          Text(caption, style: const TextStyle(fontSize: 11, color: DiabAIPalette.iconMuted)),
        ],
      ],
    );
    if (onTap == null) return column;
    return GestureDetector(onTap: onTap, child: column);
  }

  /// Buckets [GlucoseEstimate.confidencePercent] into the colored-dot bands
  /// requested for the "ATUAL" reading, so confidence reads at a glance
  /// instead of requiring the user to interpret a raw percentage.
  String _confidenceEmoji(double confidencePercent) {
    if (confidencePercent >= 90) return '\u{1F7E2}'; // 🟢
    if (confidencePercent >= 75) return '\u{1F7E1}'; // 🟡
    if (confidencePercent >= 55) return '\u{1F7E0}'; // 🟠
    return '\u{1F534}'; // 🔴
  }

  /// Deterministic, template-based summary of the current chart — not an
  /// LLM call. Sending these computed numbers through `orchestrator.respond`
  /// would risk the NLU layer misreading them as a new logged event (see
  /// AGENTS.md: the LLM only ever extracts structured events), so this
  /// assessment is authored the same way every other Nuno string in the
  /// app is: fixed text filled in with real numbers.
  String _buildAssessmentText() {
    final points = _points;
    if (points.isEmpty) return '';
    final values = points.map((p) => p.mgdl).toList();
    final current = values.last;
    final avg = values.reduce((a, b) => a + b) / values.length;
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final inRangeCount =
        values.where((v) => v >= _targetLow && v <= _targetHigh).length;
    final pctInRange = (inRangeCount / values.length * 100).round();
    final rangeLabel = '${_targetLow.toInt()}-${_targetHigh.toInt()} mg/dL';

    final buffer = StringBuffer();
    if (current > _targetHigh) {
      buffer.write(
          'Sua leitura atual, ${current.round()} mg/dL, está acima do seu intervalo-alvo ($rangeLabel).');
    } else if (current < _targetLow) {
      buffer.write(
          'Sua leitura atual, ${current.round()} mg/dL, está abaixo do seu intervalo-alvo ($rangeLabel).');
    } else {
      buffer.write(
          'Sua leitura atual, ${current.round()} mg/dL, está dentro do seu intervalo-alvo ($rangeLabel).');
    }
    buffer.write(
        ' Nas últimas ${_windowLabel(_window)} você ficou $pctInRange% do tempo no alvo, '
        'com média de ${avg.round()} mg/dL (mín. ${minV.round()}, máx. ${maxV.round()}).');
    final trendMessage = _snapshot?.current?.trendMessage;
    if (trendMessage != null && trendMessage.trim().isNotEmpty) {
      buffer.write(' Tendência: $trendMessage.');
    }
    final daysRemaining = _snapshot?.sensor?.daysRemaining();
    if (daysRemaining != null) {
      final plural = daysRemaining == 1 ? '' : 's';
      buffer.write(' Seu sensor tem cerca de $daysRemaining dia$plural restante$plural.');
    }
    return buffer.toString();
  }

  Widget _buildNunoAssessment(BuildContext context) {
    final text = _buildAssessmentText();
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DiabAIPalette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DiabAIPalette.surfaceBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.auto_awesome, size: 16, color: DiabAIPalette.accentAlt),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: DiabAIPalette.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Hands the deterministic report text to the parent shell, which
  /// expands the embedded Nuno chat overlay and surfaces it as Nuno's
  /// first message — the conversation now slides up over this page
  /// instead of navigating to a separate chat screen.
  Widget _buildReportRequest(BuildContext context) {
    final report = _buildAssessmentText();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: OutlinedButton.icon(
        onPressed:
            report.isEmpty ? null : () => widget.onOpenChat(report),
        icon: const Icon(Icons.chat_bubble_outline, size: 18),
        label: const Text('Conversar com Nuno'),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      ),
    );
  }

  Widget _buildLegend(BuildContext context) {
    Widget swatch(Color color) => Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        );
    const style = TextStyle(fontSize: 11, color: DiabAIPalette.iconMuted);
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          swatch(DiabAIPalette.accent),
          const SizedBox(width: 6),
          const Text('Sensor', style: style),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          swatch(DiabAIPalette.accentAlt),
          const SizedBox(width: 6),
          const Text('Estimativa (Kalman)', style: style),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          swatch(DiabAIPalette.online),
          const SizedBox(width: 6),
          Text(
            _hasPersonalTargets
                ? 'Seu alvo pessoal (${_targetLow.toInt()}-${_targetHigh.toInt()} mg/dL)'
                : 'Intervalo-alvo (${_targetLow.toInt()}-${_targetHigh.toInt()} mg/dL)',
            style: style,
          ),
        ]),
      ],
    );
  }

  /// Splits the sorted points into segments, breaking the line wherever the
  /// sensor gap exceeds [_maxGapForLine] so the chart never draws a
  /// misleading interpolation across missing data. The one exception is the
  /// live/current point ([_GlucosePoint.isLive]): it's always connected to
  /// the previous segment regardless of gap size, since it's confirmed to
  /// be the sensor's actual latest reading (see [_GlucosePoint.isLive]),
  /// not a stale local-history tail that genuinely went quiet.
  List<List<_GlucosePoint>> _segments() {
    final segments = <List<_GlucosePoint>>[];
    var current = <_GlucosePoint>[];
    _GlucosePoint? previous;
    for (final point in _points) {
      if (previous != null &&
          !point.isLive &&
          point.at.difference(previous.at) > _maxGapForLine) {
        if (current.isNotEmpty) segments.add(current);
        current = [];
      }
      current.add(point);
      previous = point;
    }
    if (current.isNotEmpty) segments.add(current);
    return segments;
  }

  double _xFor(DateTime at) => at.difference(_windowStart).inSeconds / 3600.0;

  /// The chart's y-axis (mg/dL) bounds \u2014 shared by [_buildChartData] (so
  /// fl_chart's own scale matches this) and [_buildHypothesisMarkers] (so a
  /// marker can be placed at the same height as the glucose curve point it
  /// explains), instead of two independent computations silently drifting
  /// apart, exactly like [_chartMaxX] does for the x-axis.
  ({double minY, double maxY}) _yRange(List<_GlucosePoint> points) {
    final estimates = _estimateSeries(points);
    final forecastSpots = _forecastSpots(points);
    final dataMax = points.map((p) => p.mgdl).reduce(math.max);
    final dataMin = points.map((p) => p.mgdl).reduce(math.min);
    final estimateMax = estimates.isEmpty
        ? dataMax
        : estimates.map((e) => e.estimatedNow).reduce(math.max);
    final estimateMin = estimates.isEmpty
        ? dataMin
        : estimates.map((e) => e.estimatedNow).reduce(math.min);
    final forecastMax = forecastSpots.isEmpty
        ? estimateMax
        : forecastSpots.map((s) => s.y).reduce(math.max);
    final forecastMin = forecastSpots.isEmpty
        ? estimateMin
        : forecastSpots.map((s) => s.y).reduce(math.min);
    final maxY =
        math.max(math.max(math.max(dataMax, estimateMax), forecastMax), _targetHigh) + 20;
    final minY = math
        .max(0, math.min(math.min(math.min(dataMin, estimateMin), forecastMin), _targetLow) - 20)
        .toDouble();
    return (minY: minY, maxY: maxY);
  }

  /// Nearest sample in [points] to [at] by absolute time distance \u2014 used
  /// by [_buildHypothesisMarkers] to find roughly where the glucose curve
  /// sits at a hypothesis's estimated peak, so its marker can float just
  /// above that point instead of a fixed height near the top of the chart.
  _GlucosePoint? _nearestPoint(List<_GlucosePoint> points, DateTime at) {
    if (points.isEmpty) return null;
    return points.reduce(
      (a, b) => a.at.difference(at).abs() < b.at.difference(at).abs() ? a : b,
    );
  }

  LineChartData _buildChartData(BuildContext context) {
    final points = _points;
    final estimates = _estimateSeries(points);
    final estimateByTime = {
      for (var i = 0; i < points.length; i++) points[i].at: estimates[i],
    };
    final forecastSpots = _forecastSpots(points);
    final (:minY, :maxY) = _yRange(points);
    final windowHours = _window.inHours.toDouble();
    final maxX = _chartMaxX(points);
    final tickInterval = (windowHours / 4).clamp(1.0, windowHours).toDouble();
    final showDate = _window.inHours > 24;
    // "Now" \u2014 anchors the AGORA line/label, the +5/+10/+15/+30 horizon
    // labels, and the shaded prediction zone to its right (request #7).
    final nowX = _xFor(points.last.at);

    return LineChartData(
      minX: 0,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      clipData: const FlClipData.all(),
      lineTouchData: LineTouchData(
        // The value itself is shown in the fixed row above the chart
        // (_buildTouchedValueRow) instead of a floating bubble, which used
        // to get clipped/hard to read near the chart's edges — keep this
        // fully transparent so only the touched-spot indicator (line + dot)
        // below still renders via the built-in touch handling.
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => Colors.transparent,
          tooltipPadding: EdgeInsets.zero,
          tooltipMargin: 0,
          getTooltipItems: (touchedSpots) =>
              touchedSpots.map((_) => null).toList(),
        ),
        touchCallback: (event, response) {
          // Two lines now share the touch surface (sensor + Kalman
          // estimate) — only the sensor's spot drives the touched-value
          // vertical line/label, exactly as before the estimate line existed.
          final spots = response?.lineBarSpots
              ?.where((s) => s.bar.color == DiabAIPalette.accent)
              .toList();
          if (!event.isInterestedForInteractions || spots == null || spots.isEmpty) {
            if (_touchedSpot != null) setState(() => _touchedSpot = null);
            return;
          }
          setState(() => _touchedSpot = spots.first);
        },
        getTouchedSpotIndicator: (barData, spotIndexes) {
          final isSensorBar = barData.color == DiabAIPalette.accent;
          return spotIndexes.map((_) {
            if (!isSensorBar) {
              return const TouchedSpotIndicatorData(
                FlLine(color: Colors.transparent, strokeWidth: 0),
                FlDotData(show: false),
              );
            }
            return TouchedSpotIndicatorData(
              FlLine(color: DiabAIPalette.textPrimary.withValues(alpha: 0.5), strokeWidth: 1),
              FlDotData(
                getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                  radius: 5,
                  color: DiabAIPalette.textPrimary,
                  strokeWidth: 2,
                  strokeColor: DiabAIPalette.accent,
                ),
              ),
            );
          }).toList();
        },
      ),
      gridData: FlGridData(
        show: true,
        horizontalInterval: 50,
        verticalInterval: tickInterval,
        getDrawingHorizontalLine: (value) => const FlLine(
          color: DiabAIPalette.surfaceBorder,
          strokeWidth: 1,
        ),
        getDrawingVerticalLine: (value) => const FlLine(
          color: DiabAIPalette.surfaceBorder,
          strokeWidth: 1,
        ),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false, reservedSize: 8)),
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: showDate ? 36 : 28,
            interval: tickInterval,
            getTitlesWidget: (value, meta) {
              // fl_chart keeps stepping ticks past the real window into the
              // reserved AGORA/forecast zone (request #4 reserves extra
              // width there); those wouldn't correspond to a real time on
              // the sensor's own axis, so hide them instead of drawing a
              // clock time that doesn't exist yet.
              if (value > windowHours + 0.01) return const SizedBox.shrink();
              final time = _windowStart.add(
                Duration(minutes: (value * 60).round()),
              );
              final hhmm =
                  '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
              final label = showDate
                  ? '${time.day.toString().padLeft(2, '0')}/${time.month.toString().padLeft(2, '0')}\n$hhmm'
                  : hhmm;
              // The tick landing on "now" gets a highlighted purple pill
              // instead of plain gray text, so the current time reads at a
              // glance (request #4).
              final isNow = (value - windowHours).abs() < 0.01;
              if (!isNow) {
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: DiabAIPalette.iconMuted,
                    ),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: DiabAIPalette.accent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: DiabAIPalette.background,
                      // Pins the pill to the glyph itself instead of the
                      // font's default line box, and reuses the same
                      // Padding(top:4) alignment as the plain tick labels
                      // (not Center, which drifted from their baseline).
                      height: 1.0,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            interval: 50,
            getTitlesWidget: (value, meta) {
              // fl_chart always adds the chart's exact minY/maxY as extra
              // ticks alongside the interval-stepped ones (see
              // AxisChartHelper.iterateThroughAxis) — skip those when they
              // don't land on a clean 50-multiple, so a value like 224
              // never renders squeezed right next to the 200 tick.
              if (value.round() % 50 != 0) return const SizedBox.shrink();
              return Text(
                value.toInt().toString(),
                style: const TextStyle(
                  fontSize: 10,
                  color: DiabAIPalette.iconMuted,
                ),
              );
            },
          ),
        ),
      ),
      rangeAnnotations: RangeAnnotations(
        horizontalRangeAnnotations: [
          HorizontalRangeAnnotation(
            y1: _targetLow,
            y2: _targetHigh,
            color: DiabAIPalette.online.withValues(alpha: 0.07),
          ),
        ],
        verticalRangeAnnotations: [
          // Discreetly marks everything right of "now" as prediction,
          // not measured data (request #7).
          if (nowX < maxX)
            VerticalRangeAnnotation(
              x1: nowX,
              x2: maxX,
              color: DiabAIPalette.accent.withValues(alpha: 0.22),
            ),
        ],
      ),
      extraLinesData: ExtraLinesData(
        verticalLines: [
          // Press-and-hold draws a dashed line straight up from the
          // touched point to the top of the chart, with the value
          // labeled there — instead of a floating tooltip bubble.
          //
          // `touched` is captured here as an immutable local so the
          // `labelResolver`/`backgroundColor` closures below never
          // dereference the mutable `_touchedSpot` field directly: fl_chart
          // invokes them lazily during paint (including mid-animation when
          // lerping between the previous and next `ExtraLinesData`), by
          // which point `_touchedSpot` may already have been set back to
          // null by a later `setState`, causing a null-check crash.
          if (_touchedSpot case final touched?)
            VerticalLine(
              x: touched.x,
              color: DiabAIPalette.textPrimary,
              strokeWidth: 1,
              dashArray: const [4, 4],
              label: VerticalLineLabel(
                show: true,
                alignment: Alignment.topCenter,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  backgroundColor:
                      touched.y >= _targetLow && touched.y <= _targetHigh
                          ? DiabAIPalette.online
                          : DiabAIPalette.offline,
                ),
                labelResolver: (_) => ' ${touched.y.round()} ',
              ),
            ),
          // Marks "now" — the boundary between real sensor history and the
          // dashed forecast — with the app's own accent purple, per request
          // #7, ending in an "AGORA" label at the top of the chart.
          VerticalLine(
            x: nowX,
            color: DiabAIPalette.accent.withValues(alpha: 0.7),
            strokeWidth: 1.4,
            dashArray: const [5, 4],
            label: VerticalLineLabel(
              show: true,
              alignment: Alignment.topCenter,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: DiabAIPalette.accent,
              ),
              labelResolver: (_) => 'AGORA',
            ),
          ),
        ],
        horizontalLines: [
          HorizontalLine(
            y: _targetHigh,
            color: DiabAIPalette.online,
            strokeWidth: 1.2,
            dashArray: const [6, 4],
            label: HorizontalLineLabel(
              show: true,
              alignment: Alignment.centerLeft,
              // No left padding — flush with the line's own start, so no
              // sliver of the dashed line shows to the left of the box.
              padding: const EdgeInsets.fromLTRB(0, 6, 6, 6),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                backgroundColor: DiabAIPalette.online,
                // Digit glyphs have no descenders, so the default
                // line-height metric makes them look vertically offset
                // within their own background-color box; height: 1.0 pins
                // the line box to the glyph itself (request #5).
                height: 1.0,
              ),
              labelResolver: (_) => ' ${_targetHigh.toInt()} ',
            ),
          ),
          HorizontalLine(
            y: _targetLow,
            color: DiabAIPalette.online,
            strokeWidth: 1.2,
            dashArray: const [6, 4],
            label: HorizontalLineLabel(
              show: true,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.fromLTRB(0, 6, 6, 6),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                backgroundColor: DiabAIPalette.online,
                height: 1.0,
              ),
              labelResolver: (_) => ' ${_targetLow.toInt()} ',
            ),
          ),
        ],
      ),
      lineBarsData: [
        for (final segment in _segments())
          LineChartBarData(
            spots: segment.map((p) => FlSpot(_xFor(p.at), p.mgdl)).toList(),
            isCurved: true,
            curveSmoothness: 0.15,
            preventCurveOverShooting: true,
            barWidth: 2.5,
            color: DiabAIPalette.accent,
            dotData: FlDotData(show: segment.length <= 3),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  DiabAIPalette.accent.withValues(alpha: 0.25),
                  DiabAIPalette.accent.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        // Physiological (Kalman) estimate \u2014 thinner and in a different
        // color than the sensor line, per design, and never shaded/filled so
        // it always reads as a secondary, derived series rather than the
        // primary data.
        for (final segment in _segments())
          LineChartBarData(
            spots: segment
                .map((p) => FlSpot(_xFor(p.at), estimateByTime[p.at]!.estimatedNow))
                .toList(),
            isCurved: true,
            curveSmoothness: 0.15,
            preventCurveOverShooting: true,
            barWidth: 1.4,
            color: DiabAIPalette.accentAlt,
            dotData: const FlDotData(show: false),
          ),
        // Forward-looking forecast (+5/+10/+15min) \u2014 dashed and in the same
        // color as the Kalman estimate line it continues from, so it reads
        // as "the same series, but now projected" rather than new data.
        if (forecastSpots.isNotEmpty)
          LineChartBarData(
            spots: forecastSpots,
            isCurved: false,
            barWidth: 1.4,
            color: DiabAIPalette.accentAlt,
            dashArray: const [4, 4],
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: index == 0 ? 0 : 2.5,
                color: DiabAIPalette.accentAlt,
              ),
            ),
          ),
      ],
    );
  }
}

/// Secondary screen for the chart's period/source filters, reached via the
/// gear icon next to the title \u2014 keeps the main chart screen free of
/// filter chips so it fits on one screen without scrolling.
class GlucoseSettingsPage extends StatefulWidget {
  const GlucoseSettingsPage({
    super.key,
    required this.window,
    required this.sourceFilter,
    required this.onWindowChanged,
    required this.onSourceFilterChanged,
  });

  final Duration window;
  final String sourceFilter;
  final ValueChanged<Duration> onWindowChanged;
  final ValueChanged<String> onSourceFilterChanged;

  @override
  State<GlucoseSettingsPage> createState() => _GlucoseSettingsPageState();
}

class _GlucoseSettingsPageState extends State<GlucoseSettingsPage> {
  late Duration _window = widget.window;
  late String _sourceFilter = widget.sourceFilter;

  @override
  Widget build(BuildContext context) {
    const labelStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: DiabAIPalette.iconMuted,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Configurações de glicemia')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('PERÍODO', style: labelStyle),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in _windowOptions)
                    ChoiceChip(
                      label: Text(_windowLabel(option)),
                      selected: option == _window,
                      onSelected: (_) {
                        if (option == _window) return;
                        setState(() => _window = option);
                        widget.onWindowChanged(option);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 24),
              const Text('FONTE', style: labelStyle),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _sourceChip('all', 'Todas'),
                  _sourceChip('manual', 'Manual'),
                  _sourceChip('cgm', 'CGM'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourceChip(String value, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _sourceFilter == value,
      onSelected: (_) {
        setState(() => _sourceFilter = value);
        widget.onSourceFilterChanged(value);
      },
    );
  }
}
