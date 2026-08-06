import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// On-device speech-to-text using a quantized Whisper Tiny model via
/// sherpa-onnx. Chosen for the DiabAI MVP because most expected voice
/// messages are very short, domain-specific phrases (e.g. "comi pão",
/// "estou em 117", "tomei 6 unidades"), so a small/fast/offline model is
/// enough and preferable to a larger general-purpose STT model.
class SttService {
  static const _encoderAssetPath = 'assets/stt/tiny-encoder.int8.onnx';
  static const _decoderAssetPath = 'assets/stt/tiny-decoder.int8.onnx';
  static const _tokensAssetPath = 'assets/stt/tiny-tokens.txt';

  sherpa_onnx.OfflineRecognizer? _recognizer;
  bool _ready = false;
  bool _initializing = false;

  bool get isReady => _ready;

  /// Copies the bundled Whisper Tiny (int8) model files to a writable
  /// directory (if not already there) and creates the offline recognizer.
  /// Safe to call multiple times.
  ///
  /// [language] should be an ISO 639-1 code (e.g. "pt", "en", "es"). When
  /// non-empty, Whisper is forced to decode in that language instead of
  /// auto-detecting it per utterance, which was causing the same short
  /// phrase to come out in Portuguese, English, or Russian depending on
  /// the recording. Pass an empty string to fall back to auto-detection.
  Future<void> ensureInitialized({String language = ''}) async {
    if (_ready || _initializing) return;
    _initializing = true;
    try {
      sherpa_onnx.initBindings();

      final encoderPath = await _copyAssetFile(_encoderAssetPath);
      final decoderPath = await _copyAssetFile(_decoderAssetPath);
      final tokensPath = await _copyAssetFile(_tokensAssetPath);

      final modelConfig = sherpa_onnx.OfflineModelConfig(
        whisper: sherpa_onnx.OfflineWhisperModelConfig(
          encoder: encoderPath,
          decoder: decoderPath,
          language: language,
          task: 'transcribe',
        ),
        tokens: tokensPath,
        modelType: 'whisper',
      );
      final config = sherpa_onnx.OfflineRecognizerConfig(model: modelConfig);
      _recognizer = sherpa_onnx.OfflineRecognizer(config);
      _ready = true;
    } finally {
      _initializing = false;
    }
  }

  Future<String> _copyAssetFile(String assetPath) async {
    final supportDir = await getApplicationSupportDirectory();
    final fileName = assetPath.split('/').last;
    final file = File('${supportDir.path}/$fileName');
    final data = await rootBundle.load(assetPath);
    if (!await file.exists() || (await file.length()) != data.lengthInBytes) {
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return file.path;
  }

  /// Transcribes a 16kHz mono WAV file (as produced by the `record`
  /// package's [AudioEncoder.wav]) into text. Returns an empty string if
  /// the service isn't ready or the file can't be decoded.
  Future<String> transcribeWavFile(String path) async {
    if (!_ready || _recognizer == null) return '';
    final bytes = await File(path).readAsBytes();
    final samples = _wavBytesToFloat32(bytes);
    if (samples.isEmpty) return '';

    final stream = _recognizer!.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      _recognizer!.decode(stream);
      return _recognizer!.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  /// Skips the WAV header (locating the "data" subchunk) and converts
  /// the remaining 16-bit PCM samples to normalized floats.
  Float32List _wavBytesToFloat32(Uint8List bytes) {
    int dataOffset = 44;
    int i = 12;
    while (i + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(i, i + 4));
      final chunkSize =
          ByteData.sublistView(bytes, i + 4, i + 8).getUint32(0, Endian.little);
      if (chunkId == 'data') {
        dataOffset = i + 8;
        break;
      }
      i += 8 + chunkSize;
    }
    if (dataOffset >= bytes.length) return Float32List(0);

    final pcm = bytes.sublist(dataOffset);
    final values = Float32List(pcm.length ~/ 2);
    final data = ByteData.sublistView(pcm);
    for (var j = 0; j + 1 < pcm.length; j += 2) {
      final short = data.getInt16(j, Endian.little);
      values[j ~/ 2] = short / 32768.0;
    }
    return values;
  }

  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _ready = false;
  }
}
