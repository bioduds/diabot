import 'dart:convert';
import 'dart:io';

import 'package:diabot/events.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> readMermaidContract(String path) {
  final source = File(path).readAsStringSync();
  final match = RegExp(r'^%% fsm-contract: (.+)$', multiLine: true)
      .firstMatch(source);
  if (match == null) {
    throw StateError('Missing fsm-contract header in $path');
  }
  return jsonDecode(match.group(1)!) as Map<String, dynamic>;
}

List<String> names(Iterable<dynamic> values) => values
  .map((value) => value.toString().split('.').last)
  .toList();

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
    expect({...activeStates, ...stubStates}.length, DiabotGlobalState.values.length);
    expect(priority.toSet().length, priority.length);
    expect(priority.toSet(), eventTypes.toSet());
  });

  test('lifecycle Mermaid contract matches auditable event transitions', () {
    final contract = readMermaidContract('$docs/lifecycle.mmd');

    expect(strings(contract, 'lifecycleEdges'), FsmContract.lifecycleEdges);
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
    expect(strings(contract, 'eventTypes'), names(FsmContract.temporalEventTypes));
    expect(strings(contract, 'consumers'), FsmContract.temporalConsumers);
    expect(contract['timestamp'], FsmContract.temporalTimestamp);
    expect(contract['globalStateChange'], FsmContract.timeEngineChangesGlobalState);
    expect(contract['lifecycleChange'], FsmContract.timeEngineChangesLifecycle);
  });

  test('initialization Mermaid contract matches the FSM entry point', () {
    final contract = readMermaidContract('$docs/initialization.mmd');

    expect(contract['entryState'], FsmContract.initializationEntryState.name);
    expect(contract['exitState'], FsmContract.initializationExitState.name);
    expect(strings(contract, 'profileFields'), FsmContract.initializationProfileFields);
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
