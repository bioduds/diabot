import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' as native;

/// App-level lifecycle for an on-device language model.
enum LLMStatus {
  uninitialized,
  loading,
  ready,
  generating,
  error,
  disposed,
}

/// Isolates the on-device Gemma 4 (LiteRT-LM) backend from the application
/// architecture. Unlike the previous `llama_cpp_dart`-based runtime, there is
/// no GBNF-style grammar constraint available here — see `IntentClassifier`
/// in `nlu.dart` for how JSON output is still enforced defensively (few-shot
/// prompting + tolerant parsing) instead of natively.
///
/// Each [generate] call opens and closes its own session: intent
/// classification is a stateless, single-turn task, so there is no
/// conversational history worth keeping alive between calls.
class LocalLLMRuntime {
  LocalLLMRuntime._(this._model);

  final InferenceModel _model;
  LLMStatus _status = LLMStatus.ready;

  LLMStatus get status => _status;

  static Future<LocalLLMRuntime> load({required String modelPath}) async {
    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(modelPath).install();

    final model = await FlutterGemma.getActiveModel(
      maxTokens: 2048,
      preferredBackend: PreferredBackend.cpu,
    );
    return LocalLLMRuntime._(model);
  }

  /// Runs one isolated completion for [prompt] and returns the model's raw
  /// text response. Throws on failure; callers (see `nlu.dart`) already
  /// treat any thrown error as an empty/unusable result.
  Future<String> generate(String prompt) async {
    if (_status == LLMStatus.disposed) {
      throw StateError('LocalLLMRuntime has been disposed.');
    }
    _status = LLMStatus.generating;
    final session = await _model.createSession(
      temperature: 0,
      topK: 1,
      maxOutputTokens: 320,
    );
    try {
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      final response = await session.getResponse();
      _status = LLMStatus.ready;
      return response;
    } catch (_) {
      _status = LLMStatus.error;
      rethrow;
    } finally {
      await session.close();
    }
  }

  Future<void> dispose() async {
    if (_status == LLMStatus.disposed) return;
    _status = LLMStatus.disposed;
    await _model.close();
  }
}

/// Isolates local embedding generation used by retrieval from the native backend.
class LocalLLMEmbeddingRuntime {
  LocalLLMEmbeddingRuntime._(this._nativeRuntime);

  native.Llama? _nativeRuntime;

  static LocalLLMEmbeddingRuntime load(String modelPath) {
    native.Llama.libraryPath ??= 'libllama.so';
    final modelParams = native.ModelParams()
      ..nGpuLayers = 0
      ..mainGpu = -1;
    final contextParams = native.ContextParams()
      ..embeddings = true
      ..poolingType = native.LlamaPoolingType.mean
      ..nCtx = 512
      ..nBatch = 512
      ..nUbatch = 512;

    return LocalLLMEmbeddingRuntime._(native.Llama(
      modelPath,
      modelParams: modelParams,
      contextParams: contextParams,
    ));
  }

  List<double> embed(String prompt) {
    final runtime = _nativeRuntime;
    if (runtime == null) throw StateError('Embedding runtime is disposed.');
    return runtime.getEmbeddings(prompt);
  }

  void dispose() {
    _nativeRuntime?.dispose();
    _nativeRuntime = null;
  }
}
