import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'llm_runtime.dart';

/// One precomputed knowledge-base chunk with its embedding vector.
class _KnowledgeChunk {
  final String id;
  final String topic;
  final String text;
  final List<double> vector;

  _KnowledgeChunk(this.id, this.topic, this.text, this.vector);
}

/// On-device retrieval-augmented-generation helper.
///
/// Loads a small precomputed knowledge base (original diabetes education
/// content, embedded offline via `tools/precompute_embeddings.py`) and,
/// at query time, embeds the user's question with a second on-device
/// EmbeddingGemma model to find the most relevant chunks via cosine
/// similarity (dot product, since vectors are L2-normalized).
class RagService {
  static const _modelAssetPath = 'assets/models/embeddinggemma-300m-Q4_0.gguf';
  static const _embeddingsAssetPath = 'assets/rag/knowledge_embeddings.json';
  static const _modelFileName = 'embeddinggemma-300m-Q4_0.gguf';

  LocalLLMEmbeddingRuntime? _embeddingRuntime;
  List<_KnowledgeChunk> _chunks = [];
  bool _ready = false;

  bool get isReady => _ready;

  /// Copies the bundled embedding model to a writable directory (if not
  /// already there), loads the embedding model, and parses the
  /// precomputed knowledge base. Safe to call multiple times.
  Future<void> ensureInitialized() async {
    if (_ready) return;

    final embeddingsRaw = await rootBundle.loadString(_embeddingsAssetPath);
    final embeddingsJson = jsonDecode(embeddingsRaw) as Map<String, dynamic>;
    final chunksJson = embeddingsJson['chunks'] as List<dynamic>;
    _chunks = chunksJson
        .map((c) => _KnowledgeChunk(
              c['id'] as String,
              c['topic'] as String,
              c['text'] as String,
              (c['vector'] as List<dynamic>).cast<num>().map((n) => n.toDouble()).toList(),
            ))
        .toList();

    final modelPath = await _ensureModelFileOnDisk();

    _embeddingRuntime = LocalLLMEmbeddingRuntime.load(modelPath);

    _ready = true;
  }

  Future<String> _ensureModelFileOnDisk() async {
    final supportDir = await getApplicationSupportDirectory();
    final file = File('${supportDir.path}/$_modelFileName');
    if (await file.exists() &&
        (await file.length()) > 0) {
      return file.path;
    }
    final bytes = await rootBundle.load(_modelAssetPath);
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    return file.path;
  }

  /// Returns the [topK] most relevant knowledge-base chunk texts for
  /// [query], or an empty list if the RAG service isn't ready yet.
  Future<List<String>> retrieve(String query, {int topK = 3}) async {
    if (!_ready || _embeddingRuntime == null || _chunks.isEmpty) return const [];

    final queryPrompt = 'task: search result | query: $query';
    final List<double> queryVector;
    try {
      queryVector = _embeddingRuntime!.embed(queryPrompt);
    } catch (_) {
      return const [];
    }

    final scored = _chunks
        .map((chunk) => MapEntry(chunk, _dot(queryVector, chunk.vector)))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return scored.take(topK).map((e) => e.key.text).toList();
  }

  double _dot(List<double> a, List<double> b) {
    final n = a.length < b.length ? a.length : b.length;
    double sum = 0.0;
    for (int i = 0; i < n; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  void dispose() {
    _embeddingRuntime?.dispose();
    _embeddingRuntime = null;
    _ready = false;
  }
}
