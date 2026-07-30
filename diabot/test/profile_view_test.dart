import 'package:diabot/profile_engine.dart';
import 'package:diabot/profile_view.dart';
import 'package:flutter_test/flutter_test.dart';

ProfileFact fact(Object value) => ProfileFact(
      value: value,
      confidence: 0.9,
      updatedAt: DateTime.utc(2026, 7, 30),
    );

void main() {
  test('groups only known facts into general data and priorities', () {
    final projection =
        ProfileViewProjection.fromProfile(ProfileSnapshot(facts: {
      'diagnosisDuration': fact('5 anos'),
      'name': fact('Ana Silva'),
      'email': fact('ana@example.com'),
      'photoUrl': fact('https://example.com/ana.jpg'),
      'cgm': fact('Libre 3'),
      'diabetesType': fact('DM1'),
      'weightKg': fact(107),
      'insulinTypes': fact('Fiasp, Glargina'),
      'insulinCarbRatio': fact('1:6'),
      'hypoglycemiaUnawareness': fact(true),
    }));

    expect(
      projection.generalItems.map((item) => item.text),
      [
        'Nome: Ana Silva',
        'E-mail: ana@example.com',
        'Peso: 107 kg',
      ],
    );
    expect(
      projection.priorityItems[0].map((item) => item.text),
      [
        'Tipo de diabetes: DM1',
        'CGM: Libre 3',
        'Insulinas: Fiasp',
        'Insulinas: Glargina',
      ],
    );
    expect(
      projection.priorityItems[1].map((item) => item.text),
      [
        'ICR: 1:6',
        'Hipoglicemia não percebida: Sim',
        'Tempo desde o diagnóstico: 5 anos',
      ],
    );
    expect(projection.photoUrl, 'https://example.com/ana.jpg');
    expect(projection.items.every((item) => !item.text.contains('?')), isTrue);
    expect(
        projection.items.every((item) => item.text.trim().isNotEmpty), isTrue);
  });

  test('always exposes completeness while hiding every unknown field', () {
    final projection = ProfileViewProjection.fromProfile(ProfileSnapshot());

    expect(projection.items, isEmpty);
    expect(projection.generalItems, isEmpty);
    expect(projection.priorityItems.every((group) => group.isEmpty), isTrue);
    expect(projection.photoUrl, isNull);
    expect(projection.completenessScore, 0);
  });

  test('keeps completeness independent from future learned facts', () {
    final known = ProfileSnapshot(facts: {
      'diabetesType': fact('DM1'),
      'weightKg': fact(107),
    });
    final withFutureFact = ProfileSnapshot(facts: {
      ...known.facts,
      'learnedFacts': fact('rotina de exercício'),
    });

    expect(withFutureFact.completenessScore, known.completenessScore);
  });
}
