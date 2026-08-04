import 'package:diabai/engines/clinical_reasoning_layer.dart';
import 'package:diabai/engines/confidence_engine.dart';
import 'package:diabai/engines/contradiction_engine.dart';
import 'package:diabai/engines/evidence_fusion_engine.dart';
import 'package:diabai/engines/hypothesis_engine.dart';
import 'package:diabai/engines/physiological_state_engine.dart';
import 'package:diabai/response_builder.dart';
import 'package:flutter_test/flutter_test.dart';

final _evidence = EvidenceSet(
  referenceTime: DateTime.utc(2026, 8, 3, 12),
  glucoseEvidence: const GlucoseEvidence(
    observed: 65,
    estimatedNow: 65,
    residual: 0,
    kalmanConfidence: 0.9,
  ),
  trendEvidence: const TrendEvidence(velocity: -0.2),
  symptomEvidence: const SymptomEvidence(),
  insulinEvidence: const InsulinEvidence(),
  exerciseEvidence: const ExerciseEvidence(),
  mealEvidence: const MealEvidence(),
);

ClinicalAssessment _assessment({
  ClinicalHypothesisType? type,
  required String tier,
}) {
  final hypotheses = type == null
      ? const <ClinicalHypothesis>[]
      : [ClinicalHypothesis(type: type, confidence: 0.8, rationale: 'test')];
  return ClinicalAssessment(
    hypotheses: hypotheses,
    dominantHypothesis: hypotheses.isEmpty ? null : hypotheses.first,
    confidence: AssessmentConfidence(
      overall: 0.5,
      tier: tier,
      perHypothesis: const {},
    ),
    evidence: _evidence,
    contradictions: const ContradictionReport(),
    physiologicalPhase: PhysiologicalPhase.stabilizing,
  );
}

void main() {
  test('renders a fixed message with no clarifying question when there is no dominant hypothesis', () {
    final text = ResponseBuilder.build(_assessment(tier: 'alta'));
    expect(text, 'N\u00e3o notei nada fora do esperado nesta leitura.');
  });

  test('uses an assertive tone for high (alta) confidence', () {
    final text = ResponseBuilder.build(
      _assessment(type: ClinicalHypothesisType.trueHypoglycemia, tier: 'alta'),
    );
    expect(text, startsWith('Isso parece ser'));
    expect(text, isNot(contains('?')));
  });

  test('uses a suggestive tone for medium (media) confidence', () {
    final text = ResponseBuilder.build(
      _assessment(type: ClinicalHypothesisType.meal, tier: 'media'),
    );
    expect(text, startsWith('Isso pode ser'));
    expect(text, isNot(contains('?')));
  });

  test('uses a tentative tone paired with a clarifying question for low (baixa) confidence when one exists', () {
    final text = ResponseBuilder.build(
      _assessment(type: ClinicalHypothesisType.sensorLag, tier: 'baixa'),
    );
    expect(text, startsWith('N\u00e3o tenho certeza'));
    expect(text, contains('medi\u00e7\u00e3o capilar'));
  });

  test('uses a tentative tone with no trailing question when the hypothesis has none', () {
    final text = ResponseBuilder.build(
      _assessment(type: ClinicalHypothesisType.dawnPhenomenon, tier: 'baixa'),
    );
    expect(text, startsWith('N\u00e3o tenho certeza'));
    expect(text, isNot(contains('?')));
  });

  test('clarifyingQuestion asks about the sensor site for a compression artifact', () {
    expect(
      ResponseBuilder.clarifyingQuestion(ClinicalHypothesisType.compressionArtifact),
      'Voc\u00ea estava deitado(a) sobre o sensor?',
    );
  });

  test('clarifyingQuestion asks for a symptom check for true hypo/hyperglycemia', () {
    expect(
      ResponseBuilder.clarifyingQuestion(ClinicalHypothesisType.trueHypoglycemia),
      contains('sintoma de hipoglicemia'),
    );
    expect(
      ResponseBuilder.clarifyingQuestion(ClinicalHypothesisType.trueHyperglycemia),
      contains('sintoma de hiperglicemia'),
    );
  });

  test('clarifyingQuestion returns null for attribution hypotheses other than dawn phenomenon', () {
    expect(ResponseBuilder.clarifyingQuestion(ClinicalHypothesisType.insulin), isNull);
    expect(ResponseBuilder.clarifyingQuestion(ClinicalHypothesisType.exercise), isNull);
    expect(ResponseBuilder.clarifyingQuestion(ClinicalHypothesisType.stress), isNull);
  });
}
