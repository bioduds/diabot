import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'cgm_sync_engine.dart';
import 'librelinkup.dart';
import 'local_db.dart';

class _GlucosePoint {
  const _GlucosePoint(this.at, this.mgdl, this.source);
  final DateTime at;
  final double mgdl;
  final String source; // 'manual' | 'cgm'
}

/// Sensor readings below/above these bounds are parsing glitches or sensor
/// noise, not real physiology \u2014 never plotted.
const double _minPlausibleMgdl = 20;
const double _maxPlausibleMgdl = 600;

/// Two readings logged within this many minutes of each other are treated
/// as the same instant (averaged) so the chart never has more than one
/// y-value for a given x \u2014 it must render a proper function.
const int _sameInstantMinutes = 1;

/// A visual break is drawn whenever consecutive readings are further apart
/// than this, instead of interpolating a line across a sensor gap.
const Duration _maxGapForLine = Duration(minutes: 20);

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
  });

  final LocalDatabase database;

  /// The app's single shared CGM background poller — reused here only to
  /// fetch a richer on-demand [LibreLinkUpSnapshot] (target range, sensor,
  /// trend/color), never to duplicate its own reading sync.
  final CgmSyncEngine cgmSyncEngine;

  @override
  State<GlucoseChartPage> createState() => _GlucoseChartPageState();
}

class _GlucoseChartPageState extends State<GlucoseChartPage> {
  bool _loading = true;
  List<_GlucosePoint> _rawPoints = const [];
  DateTime _asOf = DateTime.now();
  Duration _window = _windowOptions.first;
  String _sourceFilter = 'all'; // 'all' | 'manual' | 'cgm'

  LibreLinkUpSnapshot? _snapshot;
  bool _syncingSnapshot = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshSnapshot();
    // Reloads local data *and* re-fetches the API snapshot every minute, so
    // the time axis and the current reading never go stale between visits.
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) => _refreshAll());
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
    final rows = await widget.database.recentEventsOfType('glucose', _window);
    final raw = <_GlucosePoint>[];
    for (final row in rows) {
      try {
        final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        final value = payload['value'];
        if (value is! num) continue;
        final mgdl = value.toDouble();
        if (mgdl < _minPlausibleMgdl || mgdl > _maxPlausibleMgdl) continue;
        final source = payload['measurementContext'] == 'cgm' ? 'cgm' : 'manual';
        raw.add(_GlucosePoint(DateTime.parse(row['created_at'] as String), mgdl, source));
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
    final merged = live != null &&
            _sourceFilter != 'manual' &&
            live.timestamp.isAfter(_windowStart) &&
            (lastLocalAt == null || live.timestamp.isAfter(lastLocalAt))
        ? [...filtered, _GlucosePoint(live.timestamp, live.mgdl, 'cgm')]
        : filtered;
    final sums = <int, double>{};
    final counts = <int, int>{};
    for (final p in merged) {
      final bucketMs = p.at.millisecondsSinceEpoch ~/
          (_sameInstantMinutes * 60000) *
          (_sameInstantMinutes * 60000);
      sums[bucketMs] = (sums[bucketMs] ?? 0) + p.mgdl;
      counts[bucketMs] = (counts[bucketMs] ?? 0) + 1;
    }
    return sums.keys
        .map((ms) => _GlucosePoint(
              DateTime.fromMillisecondsSinceEpoch(ms),
              sums[ms]! / counts[ms]!,
              'mixed',
            ))
        .toList()
      ..sort((a, b) => a.at.compareTo(b.at));
  }

  static const double _defaultTargetLow = 70;
  static const double _defaultTargetHigh = 180;
  static const int _bucketCount = 4;

  /// The patient's own configured target range when the LibreLinkUp
  /// snapshot has one, falling back to the generic clinical default.
  double get _targetLow => _snapshot?.targets?.targetLow ?? _defaultTargetLow;
  double get _targetHigh => _snapshot?.targets?.targetHigh ?? _defaultTargetHigh;
  bool get _hasPersonalTargets => _snapshot?.targets?.targetLow != null;

  DateTime get _windowStart => _asOf.subtract(_window);

  _GlucosePoint? get _current => _points.isEmpty ? null : _points.last;

  List<double?> _bucketAverages() {
    final points = _points;
    final bucketSpan = _window.inMinutes / _bucketCount;
    final sums = List<double>.filled(_bucketCount, 0);
    final counts = List<int>.filled(_bucketCount, 0);
    for (final point in points) {
      final minutesFromStart = point.at.difference(_windowStart).inMinutes;
      final bucket = (minutesFromStart / bucketSpan).floor().clamp(0, _bucketCount - 1);
      sums[bucket] += point.mgdl;
      counts[bucket]++;
    }
    return List.generate(
      _bucketCount,
      (i) => counts[i] == 0 ? null : sums[i] / counts[i],
    );
  }

  @override
  Widget build(BuildContext context) {
    final points = _points;
    return Scaffold(
      appBar: AppBar(
        title: Text('Glicemia \u2014 últimas ${_windowLabel(_window)}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Configurações de glicemia',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Stack(
                children: [
                  Column(
                    children: [
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: _refreshAll,
                          child: SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(12, 16, 20, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (points.isEmpty)
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 24),
                                    child: Text(
                                      'Nenhuma leitura de glicemia registrada nesse período/filtro. '
                                      'Registre uma glicemia ou conecte um CGM no seu perfil.',
                                      textAlign: TextAlign.center,
                                    ),
                                  )
                                else ...[
                                  Center(child: _buildCurrentReading(context)),
                                  const SizedBox(height: 12),
                                  _buildHeaderRow(context),
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    height: MediaQuery.sizeOf(context).height * 0.4,
                                    child: LineChart(_buildChartData(context)),
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
                ],
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
          _load();
        },
        onSourceFilterChanged: (s) => setState(() => _sourceFilter = s),
      ),
    ));
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

  /// Maps the API's rising/falling direction to an arrow icon \u2014 one of the
  /// LibreLinkUp fields the page wasn't surfacing yet.
  IconData? _trendIcon(CgmTrend? trend) {
    switch (trend) {
      case CgmTrend.fallingQuickly:
        return Icons.keyboard_double_arrow_down;
      case CgmTrend.falling:
        return Icons.arrow_downward;
      case CgmTrend.stable:
        return Icons.arrow_forward;
      case CgmTrend.rising:
        return Icons.arrow_upward;
      case CgmTrend.risingQuickly:
        return Icons.keyboard_double_arrow_up;
      case null:
        return null;
    }
  }

  Widget _buildCurrentReading(BuildContext context) {
    final current = _current;
    if (current == null) return const SizedBox.shrink();
    final inRange = current.mgdl >= _targetLow && current.mgdl <= _targetHigh;
    final color = inRange ? DiabAIPalette.online : DiabAIPalette.offline;
    final trendIcon = _trendIcon(_snapshot?.current?.trend);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          'GLICEMIA ATUAL',
          style: TextStyle(
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
            Text(
              current.mgdl.round().toString(),
              style: TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.bold,
                color: color,
                height: 1,
              ),
            ),
            if (trendIcon != null) ...[
              const SizedBox(width: 4),
              Icon(trendIcon, size: 28, color: color),
            ],
          ],
        ),
        const SizedBox(height: 2),
        const Text(
          'mg/dL',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: DiabAIPalette.textSecondary,
          ),
        ),
      ],
    );
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

  /// Hands the deterministic report text back to `main.dart` as this page's
  /// pop result, where it's shown as a Nuno message in the real chat —
  /// asking Nuno for something belongs in the conversation, not in a second
  /// chat panel bolted onto this screen.
  Widget _buildReportRequest(BuildContext context) {
    final report = _buildAssessmentText();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: OutlinedButton.icon(
        onPressed: report.isEmpty ? null : () => Navigator.of(context).pop(report),
        icon: const Icon(Icons.chat_bubble_outline, size: 18),
        label: const Text('Pedir relatório de glicose a Nuno'),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      ),
    );
  }

  Widget _buildHeaderRow(BuildContext context) {
    final buckets = _bucketAverages();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(width: 40),
        Expanded(
          child: Row(
            children: List.generate(_bucketCount, (i) {
              final average = buckets[i];
              final inRange = average != null &&
                  average >= _targetLow &&
                  average <= _targetHigh;
              return Expanded(
                child: Text(
                  average == null ? '--' : average.round().toString(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: average == null
                        ? DiabAIPalette.iconMuted
                        : inRange
                            ? DiabAIPalette.textPrimary
                            : DiabAIPalette.offline,
                  ),
                ),
              );
            }),
          ),
        ),
      ],
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
          Text('Glicemia', style: style),
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
  /// misleading interpolation across missing data.
  List<List<_GlucosePoint>> _segments() {
    final segments = <List<_GlucosePoint>>[];
    var current = <_GlucosePoint>[];
    _GlucosePoint? previous;
    for (final point in _points) {
      if (previous != null && point.at.difference(previous.at) > _maxGapForLine) {
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

  LineChartData _buildChartData(BuildContext context) {
    final points = _points;
    final dataMax = points.map((p) => p.mgdl).reduce(math.max);
    final dataMin = points.map((p) => p.mgdl).reduce(math.min);
    final maxY = math.max(dataMax, _targetHigh) + 20;
    final minY = math.max(0, math.min(dataMin, _targetLow) - 20).toDouble();
    final windowHours = _window.inHours.toDouble();
    final tickInterval = (windowHours / 4).clamp(1.0, windowHours).toDouble();
    final showDate = _window.inHours > 24;

    return LineChartData(
      minX: 0,
      maxX: windowHours,
      minY: minY,
      maxY: maxY,
      clipData: const FlClipData.all(),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => DiabAIPalette.background.withValues(alpha: 0.92),
          getTooltipItems: (touchedSpots) => touchedSpots
              .map((spot) => LineTooltipItem(
                    '${spot.y.round()} mg/dL',
                    const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                  ))
              .toList(),
        ),
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
            reservedSize: showDate ? 32 : 24,
            interval: tickInterval,
            getTitlesWidget: (value, meta) {
              final time = _windowStart.add(
                Duration(minutes: (value * 60).round()),
              );
              final hhmm =
                  '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  showDate
                      ? '${time.day.toString().padLeft(2, '0')}/${time.month.toString().padLeft(2, '0')}\n$hhmm'
                      : hhmm,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 9,
                    color: DiabAIPalette.iconMuted,
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
            getTitlesWidget: (value, meta) => Text(
              value.toInt().toString(),
              style: const TextStyle(
                fontSize: 10,
                color: DiabAIPalette.iconMuted,
              ),
            ),
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
      ),
      extraLinesData: ExtraLinesData(
        horizontalLines: [
          HorizontalLine(
            y: _targetHigh,
            color: DiabAIPalette.online,
            strokeWidth: 1.2,
            dashArray: const [6, 4],
            label: HorizontalLineLabel(
              show: true,
              alignment: Alignment.topLeft,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                backgroundColor: DiabAIPalette.online,
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
              alignment: Alignment.bottomLeft,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                backgroundColor: DiabAIPalette.online,
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
