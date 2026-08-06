import 'events.dart';
import 'user_profile.dart';

class ProfileFact {
  const ProfileFact({
    required this.value,
    required this.confidence,
    required this.updatedAt,
  });

  final Object value;
  final double confidence;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'value': value,
        'confidence': confidence,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static ProfileFact? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final value = raw['value'];
    final confidence = raw['confidence'];
    final updatedAt = DateTime.tryParse(raw['updatedAt'] as String? ?? '');
    if (value == null || confidence is! num || updatedAt == null) return null;
    return ProfileFact(
      value: value as Object,
      confidence: confidence.toDouble(),
      updatedAt: updatedAt,
    );
  }
}

class ProfileSnapshot implements ProfileContext {
  ProfileSnapshot({Map<String, ProfileFact>? facts})
      : facts = Map.unmodifiable(facts ?? const {});

  final Map<String, ProfileFact> facts;

  @override
  Object? value(String field) => facts[field]?.value;

  @override
  double confidence(String field) => facts[field]?.confidence ?? 0;

  @override
  int get completenessScore {
    var knownWeight = 0;
    var possibleWeight = 0;
    for (var index = 0;
        index < FsmContract.profileCompletenessWeights.length;
        index++) {
      final weight = FsmContract.profileCompletenessWeights[index];
      for (final field
          in FsmContract.profileCompletenessPriorityGroups[index]) {
        if (!FsmContract.profileCompletenessFields.contains(field)) continue;
        possibleWeight += weight;
        if (facts.containsKey(field)) knownWeight += weight;
      }
    }
    if (possibleWeight == 0) return 0;
    return (knownWeight * 100 / possibleWeight).round();
  }

  @override
  List<String> get missingInformation => [
        for (final field in FsmContract.profileFields)
          if (!facts.containsKey(field)) field,
      ];

  Map<String, dynamic> toJson() => {
        'facts': {
          for (final entry in facts.entries) entry.key: entry.value.toJson(),
        },
      };

  factory ProfileSnapshot.fromJson(Map<String, dynamic> json) {
    final rawFacts = json['facts'];
    if (rawFacts is! Map) return ProfileSnapshot();
    final facts = <String, ProfileFact>{};
    for (final entry in rawFacts.entries) {
      if (entry.key is! String ||
          !FsmContract.profileFields.contains(entry.key)) {
        continue;
      }
      final fact = ProfileFact.fromJson(entry.value);
      if (fact != null) facts[entry.key as String] = fact;
    }
    return ProfileSnapshot(facts: facts);
  }
}

class ProfileEnrichment {
  const ProfileEnrichment({
    required this.profile,
    required this.changed,
  });

  final ProfileSnapshot profile;
  final bool changed;
}

/// Passively derives a profile snapshot from normal conversation. It never
/// creates questions, states, recommendations, or medical conclusions.
class ProfileEngine {
  ProfileEngine({
    this.snapshotGateway,
    Future<UserProfile> Function()? loadCurrentProfile,
    Future<void> Function(UserProfile profile)? saveCurrentProfile,
    DateTime Function()? now,
  })  : _loadCurrentProfile = loadCurrentProfile ?? UserProfile.load,
        _saveCurrentProfile =
            saveCurrentProfile ?? ((profile) => profile.save()),
        _now = now ?? DateTime.now;

  final ProfileSnapshotGateway? snapshotGateway;
  final Future<UserProfile> Function() _loadCurrentProfile;
  final Future<void> Function(UserProfile profile) _saveCurrentProfile;
  final DateTime Function() _now;

  Future<ProfileEnrichment> enrich(List<EventInstance> stack) async {
    final stored = await snapshotGateway?.loadProfileSnapshot();
    final facts = <String, ProfileFact>{
      ...ProfileSnapshot.fromJson(stored ?? const {}).facts,
    };
    var changed = _seedFromCurrentProfile(
      facts,
      await _loadCurrentProfile(),
    );

    for (final event in stack) {
      for (final candidate in _candidatesFor(event, facts)) {
        final existing = facts[candidate.field];
        if (existing?.value == candidate.value &&
            existing?.confidence == candidate.confidence) {
          continue;
        }
        facts[candidate.field] = ProfileFact(
          value: candidate.value,
          confidence: candidate.confidence,
          updatedAt: _now(),
        );
        changed = true;
      }
    }

    final profile = ProfileSnapshot(facts: facts);
    if (changed) await snapshotGateway?.saveProfileSnapshot(profile.toJson());
    return ProfileEnrichment(profile: profile, changed: changed);
  }

  /// Updates the locally selected avatar without involving the FSM event
  /// lifecycle or turning the passive engine into a questionnaire.
  Future<ProfileEnrichment> saveLocalPhoto(String photoUrl) async {
    final current = await _loadCurrentProfile();
    current.fotoUrl = photoUrl;
    await _saveCurrentProfile(current);

    final stored = await snapshotGateway?.loadProfileSnapshot();
    final facts = <String, ProfileFact>{
      ...ProfileSnapshot.fromJson(stored ?? const {}).facts,
      'photoUrl': ProfileFact(
        value: photoUrl,
        confidence: 1,
        updatedAt: _now(),
      ),
    };
    final profile = ProfileSnapshot(facts: facts);
    await snapshotGateway?.saveProfileSnapshot(profile.toJson());
    return ProfileEnrichment(profile: profile, changed: true);
  }

  bool _seedFromCurrentProfile(
    Map<String, ProfileFact> facts,
    UserProfile current,
  ) {
    var changed = false;
    void add(String field, Object? value) {
      if (value == null || facts.containsKey(field)) return;
      facts[field] = ProfileFact(
        value: value,
        confidence: 1,
        updatedAt: _now(),
      );
      changed = true;
    }

    add('name', _nonEmpty(current.nome));
    add('email', _nonEmpty(current.email));
    add('photoUrl', _nonEmpty(current.fotoUrl));
    add('diabetesType', _nonEmpty(current.tipoDiabetes));
    add('weightKg', _number(current.peso));
    add('diagnosisDuration', _nonEmpty(current.tempoDiagnostico));
    add('insulinTypes', _nonEmpty(current.insulinas));
    return changed;
  }

  Iterable<_ProfileCandidate> _candidatesFor(
    EventInstance event,
    Map<String, ProfileFact> facts,
  ) sync* {
    final confidence = _confidence(event.data['_parserConfidence']);
    if (event.type == EventType.insulin || event.type == EventType.profile) {
      final insulinType = _nonEmpty(event.data['insulinType']);
      if (insulinType != null) {
        yield _ProfileCandidate(
          'insulinTypes',
          _appendListValue(facts['insulinTypes']?.value, insulinType),
          confidence,
        );
      }
    }
    if (event.type == EventType.cgm) {
      final cgm = _nonEmpty(event.data['cgm']);
      if (cgm != null) yield _ProfileCandidate('cgm', cgm, confidence);
    }
    if (event.type != EventType.profile) return;

    for (final field in FsmContract.profileFields) {
      final value = event.data[field];
      if (value == null || (value is String && value.trim().isEmpty)) continue;
      yield _ProfileCandidate(field, value as Object, confidence);
    }
  }

  String? _nonEmpty(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  double? _number(String value) {
    final match = RegExp(r'-?\d+(?:[,.]\d+)?').firstMatch(value);
    return match == null
        ? null
        : double.tryParse(match.group(0)!.replaceAll(',', '.'));
  }

  double _confidence(Object? value) {
    final confidence = value is num ? value.toDouble() : 1.0;
    return confidence.clamp(0.5, 1.0);
  }

  String _appendListValue(Object? current, String next) {
    final values =
        current?.toString().split(',').map((value) => value.trim()).toList() ??
            [];
    if (!values.any((value) => value.toLowerCase() == next.toLowerCase())) {
      values.add(next);
    }
    return values.where((value) => value.isNotEmpty).join(', ');
  }
}

class _ProfileCandidate {
  const _ProfileCandidate(this.field, this.value, this.confidence);

  final String field;
  final Object value;
  final double confidence;
}
