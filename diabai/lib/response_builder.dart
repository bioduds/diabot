import 'engines/clinical_reasoning_layer.dart';
import 'engines/hypothesis_engine.dart';

/// See docs/fsm/response_builder.mmd. The only module allowed to turn a
/// [ClinicalAssessment] into words Nuno actually reads — fixed,
/// human-authored templates, never LLM-generated (Gemma listens, DiabAI
/// talks). Never invents a clinical judgment of its own, never proposes a
/// dose or treatment, and creates no `DiabAIGlobalState`/`EventStatus`
/// transition.
class ResponseBuilder {
  const ResponseBuilder._();

  static String build(ClinicalAssessment assessment) {
    final dominant = assessment.dominantHypothesis;
    if (dominant == null) {
      return 'N\u00e3o notei nada fora do esperado nesta leitura.';
    }

    final description = _descriptions[dominant.type]!;
    switch (assessment.confidence.tier) {
      case 'alta':
        return 'Isso parece ser $description.';
      case 'media':
        return 'Isso pode ser $description.';
      default:
        final question = clarifyingQuestion(dominant.type);
        final tentative = 'N\u00e3o tenho certeza, mas talvez isso seja $description.';
        return question == null ? tentative : '$tentative $question';
    }
  }

  /// The dominant-hypothesis-keyed clarifying question described in the V2
  /// plan (\u00a712) \u2014 sensor lag/error ask for a capillary confirmation,
  /// compression asks about the sensor site, and true hypo/hyper ask for a
  /// symptom check. Attribution hypotheses (meal/insulin/exercise/dawn/
  /// stress) have none: they are lower-stakes explanations, not concerns.
  static String? clarifyingQuestion(ClinicalHypothesisType type) =>
      _clarifyingQuestions[type];

  static const _descriptions = {
    ClinicalHypothesisType.trueHypoglycemia: 'uma hipoglicemia',
    ClinicalHypothesisType.trueHyperglycemia: 'uma hiperglicemia',
    ClinicalHypothesisType.sensorLag:
        'o sensor atrasado em rela\u00e7\u00e3o \u00e0 sua glicemia real',
    ClinicalHypothesisType.compressionArtifact:
        'uma compress\u00e3o no sensor, n\u00e3o uma queda real',
    ClinicalHypothesisType.sensorError:
        'uma falha tempor\u00e1ria de leitura do sensor',
    ClinicalHypothesisType.meal: 'reflexo de uma refei\u00e7\u00e3o recente',
    ClinicalHypothesisType.insulin: 'reflexo de uma insulina recente',
    ClinicalHypothesisType.exercise: 'reflexo de um exerc\u00edcio recente',
    ClinicalHypothesisType.dawnPhenomenon: 'o fen\u00f4meno do amanhecer',
    ClinicalHypothesisType.stress: 'reflexo de estresse',
  };

  static const _clarifyingQuestions = {
    ClinicalHypothesisType.sensorLag:
        'Voc\u00ea consegue confirmar com uma medi\u00e7\u00e3o capilar?',
    ClinicalHypothesisType.sensorError:
        'Voc\u00ea consegue confirmar com uma medi\u00e7\u00e3o capilar?',
    ClinicalHypothesisType.compressionArtifact:
        'Voc\u00ea estava deitado(a) sobre o sensor?',
    ClinicalHypothesisType.trueHypoglycemia:
        'Est\u00e1 sentindo algum sintoma de hipoglicemia agora?',
    ClinicalHypothesisType.trueHyperglycemia:
        'Est\u00e1 sentindo algum sintoma de hiperglicemia agora?',
  };
}
