import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'cgm/glucose_estimator.dart';
import 'cgm/past_event_interpreter.dart';
import 'local_db.dart';

/// A single Kalman-filtered glucose point plotted by
/// [showGlucoseCurveTimePicker] \u2014 see request #2: this is
/// [GlucoseEstimate.estimatedNow], not the raw sensor value, matching the
/// main chart's own "Estimativa (Kalman)" line. The raw sensor line is
/// intentionally not shown here (it will carry a lag disclaimer later).
class GlucoseCurvePoint {
  const GlucoseCurvePoint(this.at, this.mgdl);
  final DateTime at;
  final double mgdl;
}

const double _minPlausibleMgdl = 20;
const double _maxPlausibleMgdl = 600;

/// Widened in turn until at least two points are found, so the curve is
/// as recent/focused as possible while still being draggable.
const List<Duration> _curveWindowCandidates = [
  Duration(hours: 6),
  Duration(hours: 24),
  Duration(days: 3),
];

/// Loads recent `glucose` events for [showGlucoseCurveTimePicker], run
/// through a fresh [GlucoseEstimator] so the plotted line is the Kalman
/// estimate (see [GlucoseCurvePoint]). Returns an empty list when there
/// isn't enough local history to draw a curve \u2014 callers should fall back
/// to a plain time picker in that case.
///
/// When [centerOn] is given (e.g. a confirmed hypothesis's own estimated
/// moment \u2014 request #1), each candidate window is centered on it instead
/// of always ending at now, so the initial marker lands in the middle of
/// the plotted curve rather than at its right edge.
Future<List<GlucoseCurvePoint>> loadRecentGlucosePoints({
  DateTime? centerOn,
}) async {
  for (final window in _curveWindowCandidates) {
    final points = centerOn == null
        ? await _loadPointsWithin(window)
        : await _loadPointsCentered(centerOn, window);
    if (points.length >= 2) return points;
  }
  return const [];
}

Future<List<GlucoseCurvePoint>> _loadPointsWithin(Duration window) async {
  final rows = await LocalDatabase.instance.recentEventsOfType('glucose', window);
  return _pointsFromRows(rows, upperBound: DateTime.now());
}

Future<List<GlucoseCurvePoint>> _loadPointsCentered(
  DateTime center,
  Duration window,
) async {
  final half = Duration(milliseconds: window.inMilliseconds ~/ 2);
  final now = DateTime.now();
  var end = center.add(half);
  if (end.isAfter(now)) end = now;
  final start = center.subtract(half);
  final rows = await LocalDatabase.instance.eventsOfTypeBetween(
    'glucose',
    start,
    end,
  );
  return _pointsFromRows(rows, upperBound: now);
}

/// Parses raw event rows into chronological [GlucoseCurvePoint]s, running
/// the sorted raw readings through a fresh [GlucoseEstimator] so every
/// plotted value is [GlucoseEstimate.estimatedNow] rather than the sensor's
/// own `value` \u2014 the same Kalman line the main chart shows (request #2).
List<GlucoseCurvePoint> _pointsFromRows(
  List<Map<String, dynamic>> rows, {
  required DateTime upperBound,
}) {
  final raw = <MapEntry<DateTime, double>>[];
  for (final row in rows) {
    try {
      final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      final value = payload['value'];
      if (value is! num) continue;
      final mgdl = value.toDouble();
      if (mgdl < _minPlausibleMgdl || mgdl > _maxPlausibleMgdl) continue;
      final at = DateTime.parse(row['created_at'] as String);
      if (at.isAfter(upperBound)) continue;
      raw.add(MapEntry(at, mgdl));
    } catch (_) {
      // Skip malformed rows rather than failing the picker.
    }
  }
  raw.sort((a, b) => a.key.compareTo(b.key));
  final estimator = GlucoseEstimator();
  return [
    for (final entry in raw)
      GlucoseCurvePoint(entry.key, estimator.addReading(entry.value, entry.key).estimatedNow),
  ];
}

/// Opens the drag-on-the-curve time picker for [points] (already loaded via
/// [loadRecentGlucosePoints]) and returns the chosen [DateTime], or null if
/// the user cancels. [initialTime] (e.g. a hypothesis's own estimated
/// moment) pre-positions the marker instead of defaulting to the curve's
/// last point — see request #1. [icon] (e.g. the guided module's own icon
/// from `GuidedModuleCatalog`) is shown next to the title so the dialog
/// reads at a glance as "picking the time for this specific event type"
/// (request #2).
Future<DateTime?> showGlucoseCurveTimePicker(
  BuildContext context, {
  required List<GlucoseCurvePoint> points,
  DateTime? initialTime,
  IconData? icon,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _GlucoseCurveTimePickerDialog(
      points: points,
      initialTime: initialTime,
      icon: icon,
    ),
  );
}

double _xForTime(DateTime t, DateTime start, DateTime end, double width) {
  final totalMs = end.difference(start).inMilliseconds;
  if (totalMs <= 0) return 0;
  final fraction = t.difference(start).inMilliseconds / totalMs;
  return fraction.clamp(0.0, 1.0) * width;
}

double _yForMgdl(double mgdl, double minY, double maxY, double height) {
  final span = maxY - minY;
  if (span <= 0) return height / 2;
  return height - ((mgdl - minY) / span).clamp(0.0, 1.0) * height;
}

/// Linear interpolation of the plotted mgdl value at [t], clamped to the
/// curve's own endpoints — the marker only ever slides along real,
/// already-plotted data, never extrapolated readings.
double _mgdlAt(DateTime t, List<GlucoseCurvePoint> points) {
  if (!t.isAfter(points.first.at)) return points.first.mgdl;
  if (!t.isBefore(points.last.at)) return points.last.mgdl;
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    if (!t.isBefore(a.at) && !t.isAfter(b.at)) {
      final spanMs = b.at.difference(a.at).inMilliseconds;
      if (spanMs <= 0) return a.mgdl;
      final fraction = t.difference(a.at).inMilliseconds / spanMs;
      return a.mgdl + (b.mgdl - a.mgdl) * fraction;
    }
  }
  return points.last.mgdl;
}

/// Default target range \u2014 mirrors `_GlucoseChartPageState`'s own
/// `_defaultTargetLow`/`_defaultTargetHigh` in glucose_chart.dart. This
/// dialog has no access to the user's live snapshot targets, so it always
/// uses these defaults rather than a per-user override.
const double _defaultTargetLow = 70;
const double _defaultTargetHigh = 180;

/// Mirrors the main chart's own `_yRange` formula (glucose_chart.dart) so
/// this mini curve never looks artificially zoomed in/out relative to the
/// full chart the user just came from \u2014 request #2. Extends the data's
/// own min/max out to the target band (padded by 20) instead of the
/// previous bespoke "clamp to at least a 40 mg/dL span" logic.
(double minY, double maxY) _yRange(List<GlucoseCurvePoint> points) {
  final dataMin = points.map((p) => p.mgdl).reduce(math.min);
  final dataMax = points.map((p) => p.mgdl).reduce(math.max);
  final maxY = math.max(dataMax, _defaultTargetHigh) + 20;
  final minY = math.max(0, math.min(dataMin, _defaultTargetLow) - 20).toDouble();
  return (minY, maxY);
}

String _timeLabel(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Mirrors `_GlucoseChartPageState`'s private icon/color maps in
/// glucose_chart.dart (kept separate to avoid exposing that state class's
/// internals) \u2014 only shown for already-validated hypotheses (request #3),
/// never the pending "?" marker the main chart uses while unresolved.
const Map<HypothesisType, IconData> _validatedHypothesisIcon = {
  HypothesisType.meal: Icons.restaurant,
  HypothesisType.insulin: Icons.vaccines,
  HypothesisType.exercise: Icons.directions_run,
  HypothesisType.dawnPhenomenon: Icons.wb_twilight,
  HypothesisType.stress: Icons.sentiment_very_dissatisfied,
};

const Map<HypothesisType, Color> _validatedHypothesisColor = {
  HypothesisType.meal: Color(0xFFEF8A3D),
  HypothesisType.insulin: Color(0xFF3D8AEF),
  HypothesisType.exercise: Color(0xFF3DAE55),
  HypothesisType.dawnPhenomenon: Color(0xFFE0C23D),
  HypothesisType.stress: Color(0xFFE0475D),
};

class _GlucoseCurveTimePickerDialog extends StatefulWidget {
  const _GlucoseCurveTimePickerDialog({
    required this.points,
    this.initialTime,
    this.icon,
  });
  final List<GlucoseCurvePoint> points;
  final DateTime? initialTime;
  final IconData? icon;

  @override
  State<_GlucoseCurveTimePickerDialog> createState() =>
      _GlucoseCurveTimePickerDialogState();
}

class _GlucoseCurveTimePickerDialogState
    extends State<_GlucoseCurveTimePickerDialog> {
  final GlobalKey _plotKey = GlobalKey();
  late final DateTime _windowStart = widget.points.first.at;
  late final DateTime _windowEnd = widget.points.last.at;
  late DateTime _selected = _clampToWindow(widget.initialTime ?? _windowEnd);
  List<EventHypothesis> _validatedHypotheses = const [];

  @override
  void initState() {
    super.initState();
    _loadValidatedHypotheses();
  }

  DateTime _clampToWindow(DateTime t) {
    if (t.isBefore(_windowStart)) return _windowStart;
    if (t.isAfter(_windowEnd)) return _windowEnd;
    return t;
  }

  /// Only already-resolved hypotheses (confirmed/corrected) — the pending
  /// "?" ones are never shown here, per request #3.
  Future<void> _loadValidatedHypotheses() async {
    final stored =
        await LocalDatabase.instance.hypothesesInWindow(_windowStart, _windowEnd);
    if (!mounted) return;
    setState(() {
      _validatedHypotheses = stored
          .where((h) =>
              h.status == HypothesisStatus.confirmed ||
              h.status == HypothesisStatus.corrected)
          .toList();
    });
  }

  void _updateFromGlobal(Offset globalPosition) {
    final box = _plotKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final width = box.size.width;
    if (width <= 0) return;
    final dx = box.globalToLocal(globalPosition).dx.clamp(0.0, width);
    final totalMs = _windowEnd.difference(_windowStart).inMilliseconds;
    final newTime = totalMs <= 0
        ? _windowStart
        : _windowStart.add(Duration(milliseconds: (dx / width * totalMs).round()));
    setState(() => _selected = newTime);
  }

  @override
  Widget build(BuildContext context) {
    final (minY, maxY) = _yRange(widget.points);
    const plotHeight = 200.0;
    return Dialog(
      backgroundColor: DiabAIPalette.surface,
      insetPadding: const EdgeInsets.all(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, color: DiabAIPalette.textPrimary, size: 16),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    'Arraste o marcador sobre a curva até o horário do evento',
                    style: const TextStyle(
                      color: DiabAIPalette.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_timeLabel(_windowStart)} \u2013 ${_timeLabel(_windowEnd)}',
              style: const TextStyle(color: DiabAIPalette.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final mgdl = _mgdlAt(_selected, widget.points);
                final x = _xForTime(_selected, _windowStart, _windowEnd, width);
                final y = _yForMgdl(mgdl, minY, maxY, plotHeight);
                return GestureDetector(
                  key: _plotKey,
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (details) => _updateFromGlobal(details.globalPosition),
                  onPanUpdate: (details) => _updateFromGlobal(details.globalPosition),
                  child: SizedBox(
                    width: width,
                    height: plotHeight,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        CustomPaint(
                          size: Size(width, plotHeight),
                          painter: _CurvePainter(
                            points: widget.points,
                            windowStart: _windowStart,
                            windowEnd: _windowEnd,
                            minY: minY,
                            maxY: maxY,
                          ),
                        ),
                        // Time-axis tick labels, aligned to the same
                        // gridlines _CurvePainter draws (request #3).
                        for (final fraction in const [0.0, 0.25, 0.5, 0.75, 1.0])
                          Positioned(
                            left:
                                (fraction * width - 18).clamp(0.0, math.max(0.0, width - 36)),
                            top: plotHeight - 14,
                            child: IgnorePointer(
                              child: Text(
                                _timeLabel(_windowStart.add(Duration(
                                  milliseconds: (fraction *
                                          _windowEnd
                                              .difference(_windowStart)
                                              .inMilliseconds)
                                      .round(),
                                ))),
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: DiabAIPalette.iconMuted,
                                ),
                              ),
                            ),
                          ),
                        // Small semi-transparent icons for already-validated
                        // hypotheses in this window (request #3) — never
                        // the pending "?" marker.
                        for (final hypothesis in _validatedHypotheses)
                          if (!hypothesis.estimatedPeak.isBefore(_windowStart) &&
                              !hypothesis.estimatedPeak.isAfter(_windowEnd))
                            Positioned(
                              left: (_xForTime(
                                          hypothesis.estimatedPeak,
                                          _windowStart,
                                          _windowEnd,
                                          width) -
                                      9)
                                  .clamp(0.0, math.max(0.0, width - 18)),
                              top: (_yForMgdl(
                                          _mgdlAt(hypothesis.estimatedPeak, widget.points),
                                          minY,
                                          maxY,
                                          plotHeight) -
                                      24)
                                  .clamp(0.0, math.max(0.0, plotHeight - 18)),
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: 0.55,
                                  child: Icon(
                                    _validatedHypothesisIcon[hypothesis.type] ??
                                        Icons.circle,
                                    size: 18,
                                    color: _validatedHypothesisColor[hypothesis.type] ??
                                        DiabAIPalette.accent,
                                  ),
                                ),
                              ),
                            ),
                        Positioned(
                          left: x - 12,
                          top: y - 12,
                          child: const IgnorePointer(
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: DiabAIPalette.accent,
                              child: Icon(Icons.circle, size: 8, color: Colors.white),
                            ),
                          ),
                        ),
                        Positioned(
                          left: (x - 34).clamp(0.0, math.max(0.0, width - 68)),
                          top: math.max(0.0, y - 60),
                          child: IgnorePointer(
                            child: Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: DiabAIPalette.accent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _timeLabel(_selected),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    '${mgdl.round()} mg/dL',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(_selected),
                    child: const Text('Confirmar horário'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required this.points,
    required this.windowStart,
    required this.windowEnd,
    required this.minY,
    required this.maxY,
  });

  final List<GlucoseCurvePoint> points;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double minY;
  final double maxY;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = DiabAIPalette.surfaceBorder
      ..strokeWidth = 1;
    for (final fraction in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final linePaint = Paint()
      ..color = DiabAIPalette.accentAlt
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final offset = Offset(
        _xForTime(points[i].at, windowStart, windowEnd, size.width),
        _yForMgdl(points[i].mgdl, minY, maxY, size.height),
      );
      if (i == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _CurvePainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.minY != minY ||
      oldDelegate.maxY != maxY;
}

