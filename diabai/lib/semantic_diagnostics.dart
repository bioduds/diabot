import 'package:flutter/foundation.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'llm_runtime.dart';

class SemanticDebugSnapshot {
  const SemanticDebugSnapshot({
    required this.stage,
    required this.runtimeStatus,
    required this.timestamp,
    this.outputCharacters = 0,
    this.hasJson,
    this.eventNames = const [],
    this.confidence,
    this.timedOut = false,
    this.failure,
  });

  final String stage;
  final LLMStatus runtimeStatus;
  final DateTime timestamp;
  final int outputCharacters;
  final bool? hasJson;
  final List<String> eventNames;
  final double? confidence;
  final bool timedOut;
  final String? failure;

  bool get succeeded =>
      failure == null && hasJson == true && eventNames.isNotEmpty;

  String get summary {
    if (failure != null) return 'A geração falhou antes de produzir JSON.';
    if (timedOut) return 'A geração excedeu o tempo máximo de 30 segundos.';
    if (hasJson == false) return 'O modelo não devolveu JSON estruturado.';
    if (eventNames.isEmpty && hasJson == true) {
      return 'O JSON não continha um evento reconhecido.';
    }
    if (succeeded) return 'Evento estruturado extraído com sucesso.';
    return 'Aguardando uma interpretação.';
  }
}

/// Keeps operational diagnostics separate from health content. Neither user
/// input nor raw model output is retained here.
class SemanticDiagnostics {
  SemanticDiagnostics(this.talker);

  final Talker talker;
  final ValueNotifier<SemanticDebugSnapshot?> latest = ValueNotifier(null);

  void record(SemanticDebugSnapshot snapshot) {
    latest.value = snapshot;
    final details = 'stage=${snapshot.stage} status=${snapshot.runtimeStatus} '
        'chars=${snapshot.outputCharacters} json=${snapshot.hasJson ?? '-'} '
        'events=${snapshot.eventNames.join(',')} timeout=${snapshot.timedOut} '
        'failure=${snapshot.failure ?? '-'}';
    if (snapshot.failure != null || snapshot.timedOut) {
      talker.error('Interpretação semântica falhou: $details');
    } else {
      talker.info('Interpretação semântica: $details');
    }
  }

  void dispose() => latest.dispose();
}