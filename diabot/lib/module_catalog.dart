import 'package:flutter/material.dart';

import 'events.dart';

/// Presentation metadata for a guided module. The identifier is canonical;
/// its label is resolved from localization resources by the UI.
class GuidedModuleDefinition {
  const GuidedModuleDefinition({
    required this.id,
    required this.titleKey,
    required this.icon,
    this.eventType,
  });

  final String id;
  final String titleKey;
  final IconData icon;
  final EventType? eventType;
}

/// Canonical module registry. It contains no human-language routing rules.
class GuidedModuleCatalog {
  static const _eventModules = <EventType, GuidedModuleDefinition>{
    EventType.glucose: GuidedModuleDefinition(
      id: 'glucose',
      titleKey: 'module.glucose.title',
      icon: Icons.bloodtype_outlined,
      eventType: EventType.glucose,
    ),
    EventType.insulin: GuidedModuleDefinition(
      id: 'insulin',
      titleKey: 'module.insulin.title',
      icon: Icons.medication_outlined,
      eventType: EventType.insulin,
    ),
    EventType.meal: GuidedModuleDefinition(
      id: 'meal',
      titleKey: 'module.meal.title',
      icon: Icons.restaurant_outlined,
      eventType: EventType.meal,
    ),
    EventType.exercise: GuidedModuleDefinition(
      id: 'exercise',
      titleKey: 'module.exercise.title',
      icon: Icons.directions_run_outlined,
      eventType: EventType.exercise,
    ),
    EventType.illness: GuidedModuleDefinition(
      id: 'illness',
      titleKey: 'module.illness.title',
      icon: Icons.sick_outlined,
      eventType: EventType.illness,
    ),
    EventType.ketones: GuidedModuleDefinition(
      id: 'ketones',
      titleKey: 'module.ketones.title',
      icon: Icons.science_outlined,
      eventType: EventType.ketones,
    ),
    EventType.medication: GuidedModuleDefinition(
      id: 'medication',
      titleKey: 'module.medication.title',
      icon: Icons.medication_liquid_outlined,
      eventType: EventType.medication,
    ),
    EventType.symptoms: GuidedModuleDefinition(
      id: 'symptoms',
      titleKey: 'module.symptoms.title',
      icon: Icons.health_and_safety_outlined,
      eventType: EventType.symptoms,
    ),
  };

  static const _supportModules = <String, GuidedModuleDefinition>{
    'onboarding': GuidedModuleDefinition(
      id: 'onboarding',
      titleKey: 'module.onboarding.title',
      icon: Icons.person_add_alt_1_outlined,
    ),
    'emergency': GuidedModuleDefinition(
      id: 'emergency',
      titleKey: 'module.emergency.title',
      icon: Icons.emergency_outlined,
    ),
    'event-context': GuidedModuleDefinition(
      id: 'event-context',
      titleKey: 'module.eventContext.title',
      icon: Icons.notes_outlined,
    ),
    'profile': GuidedModuleDefinition(
      id: 'profile',
      titleKey: 'module.profile.title',
      icon: Icons.person_outline,
    ),
    'education': GuidedModuleDefinition(
      id: 'education',
      titleKey: 'module.education.title',
      icon: Icons.school_outlined,
    ),
    'cgm': GuidedModuleDefinition(
      id: 'cgm',
      titleKey: 'module.cgm.title',
      icon: Icons.sensors_outlined,
    ),
  };

  static GuidedModuleDefinition forEvent(EventType type) {
    final module = _eventModules[type];
    if (module == null) {
      throw ArgumentError.value(type, 'type', 'No guided module is registered.');
    }
    return module;
  }

  static GuidedModuleDefinition byId(String id) {
    for (final module in _eventModules.values) {
      if (module.id == id) return module;
    }
    final support = _supportModules[id];
    if (support != null) return support;
    throw ArgumentError.value(id, 'id', 'Unknown guided module.');
  }
}
