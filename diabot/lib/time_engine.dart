import 'dart:convert';

import 'events.dart';

class TemporalEvent {
  const TemporalEvent({
    required this.type,
    required this.data,
    required this.createdAt,
  });

  final EventType type;
  final Map<String, dynamic> data;
  final DateTime createdAt;
}

class TemporalSnapshot implements TemporalContext {
  const TemporalSnapshot({
    required this.referenceTime,
    required this.events,
  });

  final DateTime referenceTime;
  final List<TemporalEvent> events;

  @override
  int count(EventType type, Duration within) =>
      _eventsWithin(type, within).length;

  @override
  bool has(EventType type, Duration within) => count(type, within) > 0;

  @override
  bool hasFieldValue(
    EventType type,
    String field,
    Object value,
    Duration within,
  ) =>
      _eventsWithin(type, within).any((event) => event.data[field] == value);

  Iterable<TemporalEvent> _eventsWithin(EventType type, Duration within) =>
      events.where((event) {
        final age = referenceTime.difference(event.createdAt);
        return event.type == type && !age.isNegative && age <= within;
      });

  @override
  Duration? get timeSinceMeal => _timeSince(EventType.meal);

  @override
  Duration? get timeSinceBolus => _timeSince(
        EventType.insulin,
        fieldKey: 'insulinType',
        fieldValue: 'rapida',
      );

  @override
  Duration? get timeSinceBasal => _timeSince(
        EventType.insulin,
        fieldKey: 'insulinType',
        fieldValue: 'basal',
      );

  @override
  Duration? get timeSinceExercise => _timeSince(EventType.exercise);

  @override
  Duration? get timeSinceSymptoms => _timeSince(EventType.symptoms);

  /// Latest matching event's age, or null if none — searches the full
  /// horizon already fetched by [TimeEngine.buildContext] (up to 24h).
  Duration? _timeSince(EventType type, {String? fieldKey, Object? fieldValue}) {
    DateTime? mostRecent;
    for (final event in events) {
      if (event.type != type) continue;
      if (fieldKey != null && event.data[fieldKey] != fieldValue) continue;
      if (mostRecent == null || event.createdAt.isAfter(mostRecent)) {
        mostRecent = event.createdAt;
      }
    }
    if (mostRecent == null) return null;
    final age = referenceTime.difference(mostRecent);
    return age.isNegative ? Duration.zero : age;
  }
}

/// Builds a timestamp-based view of the current event stack and local history.
/// Reported times remain free-text context until a future module normalizes them.
class TimeEngine implements TemporalContextProvider {
  TimeEngine({
    required RecentEventReader history,
    DateTime Function()? now,
  })  : _history = history,
        _now = now ?? DateTime.now;

  final RecentEventReader _history;
  final DateTime Function() _now;

  @override
  Future<TemporalSnapshot> buildContext(List<EventInstance> stack) async {
    final referenceTime = _now();
    final events = <TemporalEvent>[
      for (final event in stack)
        if (FsmContract.temporalEventTypes.contains(event.type))
          TemporalEvent(
            type: event.type,
            data: event.data,
            createdAt: event.createdAt,
          ),
    ];
    final horizon = Duration(
      minutes: FsmContract.temporalWindows['last24Hours']!,
    );

    for (final type in FsmContract.temporalEventTypes) {
      final rows = await _history.recentEventsOfType(type.name, horizon);
      for (final row in rows) {
        final createdAt = DateTime.tryParse(row['created_at'] as String? ?? '');
        final payload = _payload(row['payload']);
        if (createdAt == null || payload == null) continue;
        events.add(TemporalEvent(
          type: type,
          data: payload,
          createdAt: createdAt,
        ));
      }
    }

    return TemporalSnapshot(referenceTime: referenceTime, events: events);
  }

  Map<String, dynamic>? _payload(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is! String) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}