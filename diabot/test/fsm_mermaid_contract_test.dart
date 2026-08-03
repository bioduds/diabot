import 'dart:convert';
import 'dart:io';

import 'package:diabai/events.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> readMermaidContract(String path) {
  final source = File(path).readAsStringSync();
  final match =
      RegExp(r'^%% fsm-contract: (.+)$', multiLine: true).firstMatch(source);
  if (match == null) {
    throw StateError('Missing fsm-contract header in $path');
  }
  return jsonDecode(match.group(1)!) as Map<String, dynamic>;
}

List<String> names(Iterable<dynamic> values) =>
    values.map((value) => value.toString().split('.').last).toList();

List<String> strings(Map<String, dynamic> contract, String key) =>
    (contract[key] as List<dynamic>).cast<String>();

void main() {
  const docs = 'docs/fsm';

  test('kernel Mermaid contract matches the declared FSM surface', () {
    final contract = readMermaidContract('$docs/kernel.mmd');
    final activeStates = names(FsmContract.activeStates);
    final stubStates = names(FsmContract.stubStates);
    final eventTypes = names(EventType.values);
    final priority = names(FsmContract.priority);

    expect(strings(contract, 'activeStates'), activeStates);
    expect(strings(contract, 'stubStates'), stubStates);
    expect(strings(contract, 'eventTypes'), eventTypes);
    expect(strings(contract, 'priority'), priority);
    expect(activeStates.toSet().intersection(stubStates.toSet()), isEmpty);
    expect({...activeStates, ...stubStates}.length,
        DiabAIGlobalState.values.length);
    expect(priority.toSet().length, priority.length);
    expect(priority.toSet(), eventTypes.toSet());
  });

  test('lifecycle Mermaid contract matches auditable event transitions', () {
    final contract = readMermaidContract('$docs/lifecycle.mmd');

    expect(strings(contract, 'lifecycleEdges'), FsmContract.lifecycleEdges);
  });

  test('Semantic Interpreter Mermaid contract preserves Kernel authority', () {
    final contract = readMermaidContract('$docs/semantic_interpreter.mmd');

    expect(strings(contract, 'inputs'), FsmContract.semanticInterpreterInputs);
    expect(strings(contract, 'outputs'), FsmContract.semanticInterpreterOutputs);
    expect(contract['minimumConfidence'],
        FsmContract.semanticInterpreterMinimumConfidence);
    expect(contract['globalStateChange'],
        FsmContract.semanticInterpreterChangesGlobalState);
    expect(contract['lifecycleChange'],
        FsmContract.semanticInterpreterChangesLifecycle);
    expect(contract['medicalReasoning'],
        FsmContract.semanticInterpreterDoesMedicalReasoning);
  });

  test('interaction modes keep the FSM and lifecycle authoritative', () {
    final contract = readMermaidContract('$docs/interaction_modes.mmd');

    expect(strings(contract, 'modes'), FsmContract.interactionModes);
    expect(contract['freeInput'], FsmContract.freeModeInput);
    expect(contract['guidedInput'], FsmContract.guidedModeInput);
    expect(contract['guidedExit'], FsmContract.guidedModeExit);
    expect(contract['globalStateChange'],
        FsmContract.interactionModesChangeGlobalState);
    expect(contract['lifecycleChange'],
        FsmContract.interactionModesChangeLifecycle);
  });

  test('Nuno persona Mermaid contract keeps persona scoped to free_reply only', () {
    final contract = readMermaidContract('$docs/nuno.mmd');

    expect(contract['appliesTo'], FsmContract.nunoAppliesTo);
    expect(contract['interactionMode'], FsmContract.nunoInteractionMode);
    expect(contract['persona'], FsmContract.nunoPersonaName);
    expect(strings(contract, 'tone'), FsmContract.nunoTone);
    expect(contract['explainsOnRequest'], FsmContract.nunoExplainsOnRequest);
    expect(contract['emergencyBehavior'], FsmContract.nunoEmergencyBehavior);
    expect(contract['medicalReasoning'],
        FsmContract.nunoDoesMedicalReasoning);
    expect(contract['insulinDoseCalculation'],
        FsmContract.nunoInsulinDoseCalculation);
    expect(contract['diagnosis'], FsmContract.nunoDiagnosis);
    expect(contract['globalStateChange'], FsmContract.nunoChangesGlobalState);
    expect(contract['lifecycleChange'], FsmContract.nunoChangesLifecycle);
    expect(contract['usesRecentContext'], FsmContract.nunoUsesRecentContext);
    expect(contract['contextWindowTurns'], FsmContract.nunoContextWindowTurns);
  });

  test('CGM Mermaid contract keeps sync scoped to profile facts and glucose events', () {
    final contract = readMermaidContract('$docs/cgm.mmd');

    expect(contract['askedDuringOnboarding'], FsmContract.cgmAskedDuringOnboarding);
    expect(strings(contract, 'profileFields'), FsmContract.cgmProfileFields);
    expect(strings(contract, 'directIntegrationProviders'),
        FsmContract.cgmDirectIntegrationProviders);
    expect(contract['integrationService'], FsmContract.cgmIntegrationService);
    expect(contract['credentialStorage'], FsmContract.cgmCredentialStorage);
    expect(contract['syncIntervalSeconds'], FsmContract.cgmSyncIntervalSeconds);
    expect(contract['syncedReadingsEventType'],
        FsmContract.cgmSyncedReadingsEventType);
    expect(contract['syncedReadingsSource'], FsmContract.cgmSyncedReadingsSource);
    expect(contract['globalStateChange'], FsmContract.cgmChangesGlobalState);
    expect(contract['lifecycleChange'], FsmContract.cgmChangesLifecycle);
    expect(contract['emergencyImpact'], FsmContract.cgmEmergencyImpact);
    expect(contract['priorityImpact'], FsmContract.cgmPriorityImpact);
    expect(contract['medicalReasoning'], FsmContract.cgmDoesMedicalReasoning);
  });

  test('module catalog keeps semantic routing and presentation separate', () {
    final contract = readMermaidContract('$docs/modules.mmd');

    expect(
      strings(contract, 'guidedEventModules'),
      names(FsmContract.guidedEventModules),
    );
    expect(strings(contract, 'supportModules'), FsmContract.supportModules);
    expect(contract['moduleIdentity'], FsmContract.moduleIdentity);
    expect(contract['titleSource'], FsmContract.moduleTitleSource);
    expect(contract['guidedControls'], FsmContract.moduleGuidedControls);
    expect(contract['semanticRouting'], FsmContract.moduleSemanticRouting);
    expect(contract['kernelHumanLanguage'],
        FsmContract.moduleKernelHumanLanguage);
    expect(contract['globalStateChange'], FsmContract.modulesChangeGlobalState);
    expect(contract['lifecycleChange'], FsmContract.modulesChangeLifecycle);
  });

  test('Meal Mermaid contract preserves generic, non-clinical collection', () {
    final contract = readMermaidContract('$docs/meal.mmd');

    expect(contract['eventType'], EventType.meal.name);
    expect(strings(contract, 'fields'), FsmContract.mealFields);
    expect(strings(contract, 'recordedPath'), FsmContract.mealRecordedPath);
    expect(strings(contract, 'plannedPath'), FsmContract.mealPlannedPath);
    expect(contract['globalStateChange'], isFalse);
    expect(contract['lifecycleChange'], isFalse);
    expect(contract['emergencyImpact'], isFalse);
    expect(contract['priorityImpact'], isFalse);
    expect(contract['medicalReasoning'], isFalse);
    expect(contract['insulinDoseCalculation'], isFalse);
  });

  test('emergency Mermaid contract matches the engine contract', () {
    final contract = readMermaidContract('$docs/emergency.mmd');

    expect(contract['precedence'], 'emergency-before-priority');
    expect(contract['resume'], 'preserve-event-stack');
    expect(strings(contract, 'signals'), EmergencyEngine.signals);
    expect(contract['threshold'], EmergencyEngine.scoreThreshold);
  });

  test('Time Engine Mermaid contract matches the temporal FSM surface', () {
    final contract = readMermaidContract('$docs/time_engine.mmd');
    final windows = contract['windows'] as List<dynamic>;
    final expectedWindows = FsmContract.temporalWindows.entries
        .map((entry) => {'name': entry.key, 'minutes': entry.value})
        .toList();

    expect(windows, expectedWindows);
    expect(
        strings(contract, 'eventTypes'), names(FsmContract.temporalEventTypes));
    expect(strings(contract, 'consumers'), FsmContract.temporalConsumers);
    expect(contract['timestamp'], FsmContract.temporalTimestamp);
    expect(contract['globalStateChange'],
        FsmContract.timeEngineChangesGlobalState);
    expect(contract['lifecycleChange'], FsmContract.timeEngineChangesLifecycle);
  });

  test('Profile Engine Mermaid contract remains passive', () {
    final contract = readMermaidContract('$docs/profile_engine.mmd');

    expect(strings(contract, 'profileFields'), FsmContract.profileFields);
    expect(strings(contract, 'sources'), FsmContract.profileSources);
    expect(strings(contract, 'outputs'), FsmContract.profileOutputs);
    expect(strings(contract, 'consumers'), FsmContract.profileConsumers);
    expect(contract['persistence'], FsmContract.profilePersistence);
    expect(contract['globalStateChange'],
        FsmContract.profileEngineChangesGlobalState);
    expect(
        contract['lifecycleChange'], FsmContract.profileEngineChangesLifecycle);
    expect(contract['asksQuestions'], FsmContract.profileEngineAsksQuestions);
    expect(contract['medicalReasoning'],
        FsmContract.profileEngineDoesMedicalReasoning);
  });

  test('global context Mermaid contract preserves the kernel surface', () {
    final contract = readMermaidContract('$docs/global_context.mmd');

    expect(strings(contract, 'outputs'), FsmContract.profileConsumers);
    expect(strings(contract, 'profileConsumers'), FsmContract.profileConsumers);
    expect(contract['globalStateChange'], isFalse);
    expect(contract['lifecycleChange'], isFalse);
  });

  test('profile fact lifecycle remains outside the FSM lifecycle', () {
    final contract = readMermaidContract('$docs/profile_lifecycle.mmd');

    expect(strings(contract, 'steps'), FsmContract.profileLifecycleSteps);
    expect(contract['globalStateChange'], isFalse);
    expect(contract['eventLifecycleChange'], isFalse);
    expect(contract['asksQuestions'], isFalse);
  });

  test('Profile View Mermaid contract remains a known-only projection', () {
    final contract = readMermaidContract('$docs/profile_view.mmd');
    final groups = (contract['priorityGroups'] as List<dynamic>)
        .map((group) => (group as List<dynamic>).cast<String>())
        .toList();

    expect(strings(contract, 'generalFields'), FsmContract.profileViewGeneralFields);
    expect(groups, FsmContract.profileViewPriorityGroups);
    expect(
      strings(contract, 'avatarSources'),
      FsmContract.profileViewAvatarSources,
    );
    expect(contract['knownOnly'], FsmContract.profileViewKnownOnly);
    expect(contract['dynamic'], FsmContract.profileViewDynamic);
    expect(contract['sort'], FsmContract.profileViewSort);
    expect(contract['completeness'], FsmContract.profileViewCompleteness);
    expect(contract['completenessScore'], FsmContract.profileCompletenessScore);
    expect(contract['globalStateChange'],
        FsmContract.profileViewChangesGlobalState);
    expect(
        contract['lifecycleChange'], FsmContract.profileViewChangesLifecycle);
    expect(contract['asksQuestions'], FsmContract.profileViewAsksQuestions);
    expect(contract['medicalReasoning'],
        FsmContract.profileViewDoesMedicalReasoning);
  });

  test('initialization Mermaid contract matches the FSM entry point', () {
    final contract = readMermaidContract('$docs/initialization.mmd');

    expect(contract['entryState'], FsmContract.initializationEntryState.name);
    expect(contract['exitState'], FsmContract.initializationExitState.name);
    expect(strings(contract, 'profileFields'),
        FsmContract.initializationProfileFields);
    expect(contract['persistence'], 'local-profile-on-complete');
    expect(contract['reentry'], 'saved-profile-skips-onboarding');
    expect(contract['modelGate'], FsmContract.initializationModelGate);
    expect(contract['modelFailure'], FsmContract.initializationModelFailure);
    expect(contract['eventLifecycleChange'], isFalse);
    expect(contract['emergencyImpact'], isFalse);
    expect(contract['priorityImpact'], isFalse);
    expect(contract['knowledgeImpact'], isFalse);
  });
}
