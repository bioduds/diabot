import 'package:diabot/events.dart';
import 'package:diabot/initialization.dart';
import 'package:diabot/orchestrator.dart';
import 'package:diabot/time_engine.dart';
import 'package:diabot/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryGateway implements FsmStoreGateway {
  final events = <EventInstance>[];
  final transitions = <KernelTransition>[];

  @override
  Future<void> recordTransition(KernelTransition transition) async {
    transitions.add(transition);
  }

  @override
  Future<void> storeEvent(EventInstance event) async {
    events.add(event);
  }

  @override
  Future<void> storeSystemEvent(String type, Map<String, dynamic> data) async {}
}

class _TemporalProvider implements TemporalContextProvider {
  @override
  Future<TemporalContext> buildContext(List<EventInstance> stack) async {
    final now = DateTime.now();
    return TemporalSnapshot(
      referenceTime: now,
      events: [
        ...stack.map((event) => TemporalEvent(
              type: event.type,
              data: event.data,
              createdAt: event.createdAt,
            )),
        TemporalEvent(
          type: EventType.insulin,
          data: const {'dose': 20},
          createdAt: now.subtract(const Duration(minutes: 40)),
        ),
        TemporalEvent(
          type: EventType.exercise,
          data: const {'intensity': 'intensa'},
          createdAt: now.subtract(const Duration(minutes: 30)),
        ),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('quick reply reaches the FSM without an LLM parser', () async {
    final orchestrator = ConversationOrchestrator();

    final reply = await orchestrator.respond('Uma refeição', null);

    expect(reply.text, contains('gramas de carboidratos'));
    expect(reply.quickReplies, ['Sim, sei', 'Não sei']);
  });

  test('onboarding is an FSM entry point that exits after saving profile', () async {
    final orchestrator = ConversationOrchestrator(
      initializationModule: InitializationModule(),
    );

    final first = await orchestrator.beginOnboarding(
      profile: UserProfile(),
      deviceLanguage: 'pt',
      accountDisplayName: 'Ana',
    );
    await orchestrator.respond('70 kg', null);
    await orchestrator.respond('Tipo 1', null);
    await orchestrator.respond('3 anos', null);
    final completed = await orchestrator.respond('Fiasp', null);

    expect(first.text, contains('peso atual'));
    expect(orchestrator.state, DiabotGlobalState.idle);
    expect(completed.text, contains('Perfil inicial salvo'));
    expect(completed.quickReplies, contains('Registrar glicemia'));
  });

  test('bare glucose value reaches the FSM without an LLM parser', () async {
    final orchestrator = ConversationOrchestrator();

    final reply = await orchestrator.respond('118', null);

    expect(reply.text, contains('alguma insulina'));
    expect(reply.quickReplies, ['Sim', 'Não']);
  });

  test('completed events are stored with an auditable lifecycle', () async {
    final gateway = _MemoryGateway();
    final orchestrator = ConversationOrchestrator(storeGateway: gateway);

    await orchestrator.respond('Uma refeição', null);
    await orchestrator.respond('Não sei', null);
    final reply = await orchestrator.respond('Continuar sem contexto', null);

    expect(reply.text, contains('Registrado'));
    expect(reply.text, contains('O que você quer fazer agora'));
    expect(reply.quickReplies, contains('Registrar insulina'));
    expect(gateway.events, hasLength(1));
    expect(gateway.events.single.status, EventStatus.stored);
    expect(
      gateway.transitions.map((transition) => transition.to),
      containsAll([EventStatus.waitingInformation, EventStatus.validating, EventStatus.stored]),
    );
  });

  test('invalid complete data is discarded with a reason', () async {
    final gateway = _MemoryGateway();
    final orchestrator = ConversationOrchestrator(storeGateway: gateway);

    await orchestrator.respond('Uma refeição', null);
    await orchestrator.respond('Sim', null);
    await orchestrator.respond('-1', null);
    final reply = await orchestrator.respond('Continuar sem contexto', null);

    expect(reply.text, contains('não é válido'));
    expect(gateway.events, isEmpty);
    expect(gateway.transitions.last.to, EventStatus.discarded);
    expect(gateway.transitions.last.reason, contains('non-negative'));
  });

  test('emergency preempts and then resumes the pending event', () async {
    final gateway = _MemoryGateway();
    final orchestrator = ConversationOrchestrator(storeGateway: gateway);

    final first = await orchestrator.respond('45', null);
    final second = await orchestrator.respond('Sim', null);
    final resumed = await orchestrator.respond('Tenho alguém', null);

    expect(first.text, contains('emergência'));
    expect(second.text, contains('sozinho'));
    expect(resumed.text, contains('alguma insulina'));
    expect(
      gateway.transitions.map((transition) => transition.to),
      contains(EventStatus.escalated),
    );
  });

  test('emergency reply makes temporal context visible', () async {
    final orchestrator = ConversationOrchestrator(
      emergencyEngine: EmergencyEngine(
        temporalContextProvider: _TemporalProvider(),
      ),
    );

    final reply = await orchestrator.respond('77', null);

    expect(reply.text, contains('contexto temporal local'));
    expect(reply.text, contains('insulina rápida recente'));
    expect(reply.text, contains('exercício intenso recente'));
  });

  test('optional event context is retained before storage', () async {
    final gateway = _MemoryGateway();
    final orchestrator = ConversationOrchestrator(storeGateway: gateway);

    await orchestrator.respond('Uma refeição', null);
    await orchestrator.respond('Não sei', null);
    await orchestrator.respond('Adicionar contexto', null);
    await orchestrator.respond('Agora', null);
    await orchestrator.respond('Em casa', null);
    final reply = await orchestrator.respond('Cheguei do exercício', null);

    expect(reply.text, contains('Registrado'));
    expect(gateway.events.single.data['occurredWhen'], 'agora');
    expect(gateway.events.single.data['location'], 'em casa');
    expect(gateway.events.single.data['contextReason'], 'Cheguei do exercício');
  });

  test('education suggestion accepts the next utterance as a question', () async {
    final orchestrator = ConversationOrchestrator(
      onEducationRequest: (question) async => 'Resposta para: $question',
    );

    final prompt = await orchestrator.respond('Tenho uma dúvida', null);
    final answer = await orchestrator.respond('O que são cetonas?', null);

    expect(prompt.text, 'Qual é sua dúvida?');
    expect(answer.text, contains('Resposta para: O que são cetonas?'));
  });
}
