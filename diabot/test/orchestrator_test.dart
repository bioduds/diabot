import 'package:diabot/events.dart';
import 'package:diabot/initialization.dart';
import 'package:diabot/nlu.dart';
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

class _SemanticInterpreter implements SemanticInterpreter {
  const _SemanticInterpreter(this.extraction);

  final NluExtraction extraction;

  @override
  Future<NluExtraction> interpret(String userText) async => extraction;
}

const _mealInterpreter = _SemanticInterpreter(NluExtraction(
  events: [EventType.meal],
  confidence: 0.9,
));

const _insulinInterpreter = _SemanticInterpreter(NluExtraction(
  events: [EventType.insulin],
  confidence: 0.9,
));

const _questionInterpreter = _SemanticInterpreter(NluExtraction(
  events: [EventType.question],
  confidence: 0.9,
));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('meal collection first distinguishes a recorded meal from a plan',
      () async {
    final orchestrator = ConversationOrchestrator();

    final reply = await orchestrator.respond('free input', _mealInterpreter);

    expect(reply.text, contains('já se alimentou'));
    expect(reply.quickReplies, ['Já comi', 'Ainda não comi', 'Outras opções']);
  });

  test('semantic meal interpretation starts the Meal flow from natural language',
      () async {
    final orchestrator = ConversationOrchestrator();
    const interpreter = _SemanticInterpreter(NluExtraction(
      events: [EventType.meal],
      confidence: 0.85,
    ));

    final reply =
        await orchestrator.respond('Agora a fome apertou', interpreter);

    expect(reply.text, contains('já se alimentou'));
    expect(reply.quickReplies, contains('Outras opções'));
    expect(reply.guidedFieldKind, FieldKind.option);
    expect(reply.guidedModuleId, EventType.meal.name);
  });

  test('leaving guided mode preserves the pending event for a later turn',
      () async {
    final orchestrator = ConversationOrchestrator();

    final guided = await orchestrator.respond('free input', _mealInterpreter);
    final free = await orchestrator.exitGuidedMode();
    final resumed = await orchestrator.respond('Já comi', null);

    expect(guided.guidedFieldKind, FieldKind.option);
    expect(free.guidedFieldKind, isNull);
    expect(free.text, contains('escrever livremente'));
    expect(resumed.text, contains('carboidratos'));
  });

  test('low-confidence semantic interpretation remains in free mode',
      () async {
    final orchestrator = ConversationOrchestrator();
    const interpreter = _SemanticInterpreter(NluExtraction(
      events: [EventType.meal],
      confidence: 0.49,
    ));

    final reply =
        await orchestrator.respond('Agora a fome apertou', interpreter);

    expect(reply.text, contains('Não consegui interpretar'));
    expect(reply.guidedFieldKind, isNull);
    expect(reply.quickReplies, isNull);
  });

  test('unknown semantic input presents the LLM free-text response', () async {
    final orchestrator = ConversationOrchestrator();
    const interpreter = _SemanticInterpreter(NluExtraction(
      events: [EventType.unknown],
      confidence: 0.8,
      freeTextResponse: 'Claro. Me conte mais sobre isso.',
    ));

    final reply = await orchestrator.respond('Quero conversar', interpreter);

    expect(reply.text, 'Claro. Me conte mais sobre isso.');
    expect(reply.guidedFieldKind, isNull);
  });

  test('other options opens a generic menu without discarding Meal',
      () async {
    final orchestrator = ConversationOrchestrator();

    await orchestrator.respond('free input', _mealInterpreter);
    final menu = await orchestrator.respond('Outras opções', null);
    final insulin = await orchestrator.respond('free input', _insulinInterpreter);

    expect(menu.text, contains('Escolha o que você quer registrar'));
    expect(menu.quickReplies, containsAll([
      'Uma refeição',
      'Minha glicemia',
      'Uma dose de insulina',
      'Registrar medicamento',
    ]));
    expect(insulin.text, contains('Quantas unidades'));
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
    expect(reply.quickReplies, ['Sim', 'Não', 'Outras opções']);
  });

  test('completed events are stored with an auditable lifecycle', () async {
    final gateway = _MemoryGateway();
    final orchestrator = ConversationOrchestrator(storeGateway: gateway);

    await orchestrator.respond('free input', _mealInterpreter);
    await orchestrator.respond('Já comi', null);
    await orchestrator.respond('Não sei', null);
    await orchestrator.respond('Não agora', null);
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

    await orchestrator.respond('free input', _mealInterpreter);
    await orchestrator.respond('Já comi', null);
    await orchestrator.respond('Sim', null);
    await orchestrator.respond('-1', null);
    await orchestrator.respond('Não agora', null);
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

    await orchestrator.respond('free input', _mealInterpreter);
    await orchestrator.respond('Já comi', null);
    await orchestrator.respond('Não sei', null);
    await orchestrator.respond('Não agora', null);
    await orchestrator.respond('Adicionar contexto', null);
    await orchestrator.respond('Agora', null);
    await orchestrator.respond('Em casa', null);
    final reply = await orchestrator.respond('Cheguei do exercício', null);

    expect(reply.text, contains('Registrado'));
    expect(gateway.events.single.data['occurredWhen'], 'agora');
    expect(gateway.events.single.data['location'], 'em casa');
    expect(gateway.events.single.data['contextReason'], 'Cheguei do exercício');
  });

  test('planned meal records foods and a stated carbohydrate estimate',
      () async {
    final gateway = _MemoryGateway();
    final orchestrator = ConversationOrchestrator(storeGateway: gateway);

    await orchestrator.respond('free input', _mealInterpreter);
    final foods = await orchestrator.respond('Ainda não comi', null);
    final estimate = await orchestrator.respond('Arroz, feijão e frango', null);
    final grams = await orchestrator.respond('Sim, tenho', null);
    await orchestrator.respond('70', null);
    final completed =
        await orchestrator.respond('Continuar sem contexto', null);

    expect(foods.text, contains('Quais alimentos'));
    expect(estimate.text, contains('estimativa dos carboidratos'));
    expect(grams.text, contains('Quantos gramas'));
    expect(completed.text, contains('Planejamento registrado'));
    expect(gateway.events.single.data['mealStatus'], 'planned');
    expect(gateway.events.single.data['plannedFoods'], 'Arroz, feijão e frango');
    expect(gateway.events.single.data['plannedCarbsGrams'], 70);
  });

  test('recorded meal stores optional consumed-food context', () async {
    final gateway = _MemoryGateway();
    final orchestrator = ConversationOrchestrator(storeGateway: gateway);

    await orchestrator.respond('free input', _mealInterpreter);
    await orchestrator.respond('Já comi', null);
    await orchestrator.respond('Sim, sei', null);
    await orchestrator.respond('45', null);
    final details = await orchestrator.respond('Quero detalhar', null);
    await orchestrator.respond('Pão integral com queijo', null);
    await orchestrator.respond('Continuar sem contexto', null);

    expect(details.text, contains('O que você comeu'));
    expect(gateway.events.single.data['foodDetails'], 'Pão integral com queijo');
    expect(gateway.events.single.data['carbsGrams'], 45);
  });

  test('education suggestion accepts the next utterance as a question', () async {
    final orchestrator = ConversationOrchestrator(
      onEducationRequest: (question) async => 'Resposta para: $question',
    );

    final answer = await orchestrator.respond(
      'O que são cetonas?',
      _questionInterpreter,
    );

    expect(answer.text, contains('Resposta para: O que são cetonas?'));
  });
}
