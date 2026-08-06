import 'dart:convert';

import 'package:diabai/librelinkup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Map<String, dynamic> body, {int statusCode = 200}) =>
    http.Response(jsonEncode(body), statusCode);

void main() {
  test('connect() logs in and returns the first linked patient', () async {
    final client = LibreLinkUpClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/llu/auth/login') {
          return _json({
            'data': {
              'authTicket': {'token': 'token-123'},
              'user': {'id': 'user-1'},
            },
          });
        }
        if (request.url.path == '/llu/connections') {
          return _json({
            'data': [
              {'patientId': 'patient-1', 'firstName': 'Ana', 'lastName': 'Silva'},
            ],
          });
        }
        return http.Response('not found', 404);
      }),
    );

    final result = await client.connect(email: 'a@b.com', password: 'x');

    expect(result.token, 'token-123');
    expect(result.patient.patientId, 'patient-1');
    expect(result.patient.fullName, 'Ana Silva');
    // sha256("user-1") hex, precomputed for a stable expectation.
    expect(result.accountIdHash.length, 64);
  });

  test('connect() follows a regional redirect before fetching patients',
      () async {
    var loginCalls = 0;
    final client = LibreLinkUpClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/llu/auth/login') {
          loginCalls += 1;
          if (request.url.host.contains('api-la')) {
            return _json({
              'data': {'redirect': true, 'region': 'eu'},
            });
          }
          return _json({
            'data': {
              'authTicket': {'token': 'token-eu'},
              'user': {'id': 'user-2'},
            },
          });
        }
        if (request.url.path == '/llu/connections') {
          return _json({
            'data': [
              {'patientId': 'patient-2', 'firstName': 'Bea', 'lastName': ''},
            ],
          });
        }
        return http.Response('not found', 404);
      }),
    );

    final result =
        await client.connect(email: 'a@b.com', password: 'x', regionCode: 'LA');

    expect(loginCalls, 2);
    expect(result.region.code, 'EU');
    expect(result.token, 'token-eu');
  });

  test('connect() throws for invalid credentials', () async {
    final client = LibreLinkUpClient(
      httpClient: MockClient((request) async => http.Response('', 401)),
    );

    expect(
      () => client.connect(email: 'a@b.com', password: 'wrong'),
      throwsA(isA<LibreLinkUpException>()),
    );
  });

  test('connect() throws when the account has no linked patients', () async {
    final client = LibreLinkUpClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/llu/auth/login') {
          return _json({
            'data': {
              'authTicket': {'token': 'token-123'},
              'user': {'id': 'user-1'},
            },
          });
        }
        return _json({'data': <dynamic>[]});
      }),
    );

    expect(
      () => client.connect(email: 'a@b.com', password: 'x'),
      throwsA(isA<LibreLinkUpException>()),
    );
  });

  test('fetchGraphReadings() parses timestamp, mg/dL value, and trend',
      () async {
    final client = LibreLinkUpClient(
      httpClient: MockClient((request) async {
        return _json({
          'data': {
            'graphData': [
              {
                'FactoryTimestamp': '8/2/2026 3:45:00 PM',
                'ValueInMgPerDl': 120,
                'TrendArrow': 3,
              },
              {
                'FactoryTimestamp': '8/2/2026 3:50:00 PM',
                'ValueInMgPerDl': 135,
                'TrendArrow': 4,
              },
            ],
          },
        });
      }),
    );

    final readings = await client.fetchGraphReadings(
      region: LibreLinkUpRegion.fromCode('US'),
      token: 'token',
      accountIdHash: 'hash',
      patientId: 'patient-1',
    );

    expect(readings, hasLength(2));
    expect(readings.first.mgdl, 120);
    expect(readings.first.trend, 'stable');
    expect(readings.last.mgdl, 135);
    expect(readings.last.trend, 'rising');
    expect(readings.first.timestamp.isBefore(readings.last.timestamp), isTrue);
  });
}
