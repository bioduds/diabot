import 'dart:convert';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'login_page.dart';
import 'onboarding_page.dart';
import 'rag.dart';
import 'stt.dart';
import 'user_profile.dart';

const _kLastBuildNumberKey = 'diabot_last_build_number';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Hide the status/navigation bars like a typical full-screen Android app;
  // swiping from the bottom edge temporarily reveals them again.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await Firebase.initializeApp();
  await _resetLocalDataOnNewBuild();
  runApp(const DiabotApp());
}

/// During active testing, every fresh debug install should start from a
/// clean login/onboarding flow instead of reusing whatever Firebase session
/// or saved [UserProfile] happened to be left over from a previous test
/// round (`adb install -r` preserves all app data across reinstalls).
///
/// This compares the running build number (bumped in pubspec.yaml before
/// each test build) against the last one seen, stored in SharedPreferences.
/// If it changed, all local app data is wiped: the saved profile, and the
/// cached Firebase/Google sign-in session.
Future<void> _resetLocalDataOnNewBuild() async {
  final info = await PackageInfo.fromPlatform();
  final prefs = await SharedPreferences.getInstance();
  final lastBuildNumber = prefs.getString(_kLastBuildNumberKey);
  if (lastBuildNumber == info.buildNumber) return;

  await prefs.clear();
  await GoogleSignIn().signOut();
  await FirebaseAuth.instance.signOut();
  await prefs.setString(_kLastBuildNumberKey, info.buildNumber);
}

class DiabotApp extends StatelessWidget {
  const DiabotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Diabot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

/// Shows [LoginPage] when signed out, [ChatPage] when signed in (after
/// completing the first-login [OnboardingPage] if no profile is saved yet).
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return snapshot.data != null
            ? const _PostAuthGate()
            : const LoginPage();
      },
    );
  }
}

/// Decides between the onboarding flow and the chat page once the user is
/// signed in, based on whether a [UserProfile] has already been saved.
class _PostAuthGate extends StatefulWidget {
  const _PostAuthGate();

  @override
  State<_PostAuthGate> createState() => _PostAuthGateState();
}

class _PostAuthGateState extends State<_PostAuthGate> {
  bool? _onboardingComplete;

  @override
  void initState() {
    super.initState();
    _checkProfile();
  }

  Future<void> _checkProfile() async {
    final complete = await UserProfile.isComplete();
    if (mounted) setState(() => _onboardingComplete = complete);
  }

  @override
  Widget build(BuildContext context) {
    if (_onboardingComplete == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_onboardingComplete == false) {
      return OnboardingPage(
        onDone: (_) => setState(() => _onboardingComplete = true),
      );
    }
    return const ChatPage();
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class Message {
  final String role;
  final String text;

  Message(this.role, this.text);
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _controller = TextEditingController();
  final List<Message> _messages = [];
  bool _isLoading = false;
  // On-device Llama parent + streaming helpers
  LlamaParent? _llamaParent;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<CompletionEvent>? _compSub;
  bool _modelLoading = false;
  UserProfile _profile = UserProfile();
  final RagService _rag = RagService();

  // Voice input (mic button) state. Recording is captured as a 16kHz mono
  // WAV file and transcribed on-device with Whisper Tiny (via SttService)
  // once recording stops.
  final AudioRecorder _audioRecorder = AudioRecorder();
  final SttService _stt = SttService();
  bool _isRecording = false;
  bool _isTranscribing = false;
  Duration _recordingElapsed = Duration.zero;
  Timer? _recordingTimer;

  @override
  void initState() {
    super.initState();
    _loadProfile().then((_) {
      // Fire-and-forget: loads the on-device Whisper Tiny STT model,
      // forcing decoding to the user's known language (from onboarding /
      // device locale) so it doesn't randomly guess Portuguese, English,
      // or Russian per recording. If it fails, the mic button will simply
      // show an error when tapped.
      _stt.ensureInitialized(language: _profile.idioma).catchError((_) {});
    });
    // Fire-and-forget: loads the on-device embedding model + knowledge base
    // in the background. If it fails (e.g. low storage), RAG context is
    // simply skipped and the chat still works with the base system prompt.
    _rag.ensureInitialized().catchError((_) {});
  }

  Future<void> _loadProfile() async {
    final profile = await UserProfile.load();
    if (mounted) setState(() => _profile = profile);
  }

  Future<void> _editProfile() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OnboardingPage(
        existingProfile: _profile,
        onDone: (updated) => Navigator.of(context).pop(updated),
      ),
    ));
    await _loadProfile();
  }

  Future<void> _sendMessage() async {
    final prompt = _controller.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _messages.add(Message('user', prompt));
      _controller.clear();
      _isLoading = true;
    });

    final responseText = await _queryOllama(prompt);

    setState(() {
      _messages.add(Message('assistant', responseText));
      _isLoading = false;
    });
  }

  static const _baseSystemPrompt =
      'Você é uma IA especializada em educação sobre diabetes. Seu objetivo é ensinar, explicar conceitos e auxiliar o usuário a compreender melhor sua condição. Você nunca substitui profissionais de saúde. Você deverá: ensinar; explicar; acolher; reconhecer incertezas; adaptar a profundidade das respostas ao contexto apresentado. Você NÃO deverá: prescrever tratamentos; substituir profissionais de saúde; apresentar certezas inexistentes; realizar recomendações perigosas ou categóricas. Seu principal objetivo é aumentar a autonomia do usuário ao longo do tempo.';

  /// Combines the base instructions with the saved user profile and any
  /// retrieved RAG knowledge-base chunks into a single system prompt.
  Future<String> _buildSystemPrompt(String userPrompt) async {
    final parts = <String>[_baseSystemPrompt];
    final profileSummary = _profile.toPromptSummary();
    if (profileSummary.isNotEmpty) parts.add(profileSummary);

    final ragChunks = await _rag.retrieve(userPrompt);
    if (ragChunks.isNotEmpty) {
      parts.add('Conteúdo de referência (use se for relevante para a '
          'pergunta, não mencione que veio de uma "base de dados"):\n'
          '- ${ragChunks.join('\n- ')}');
    }

    return parts.join('\n\n');
  }

  Future<String> _queryOllama(String prompt) async {
    final systemPrompt = await _buildSystemPrompt(prompt);

    // If an on-device LlamaParent is initialized, use it.
    if (_llamaParent != null && _llamaParent!.status == LlamaStatus.ready) {
      final chatHistory = ChatHistory();
      chatHistory.addMessage(role: Role.system, content: systemPrompt);
      chatHistory.addMessage(role: Role.user, content: prompt);

      // Prepare to capture streaming tokens and completion
      final completer = Completer<void>();
      final buffer = StringBuffer();

      // token stream
      _tokenSub = _llamaParent!.stream.listen((token) {
        buffer.write(token);
      }, onError: (e) {
        // ignore stream errors here
      });

      // completion events
      _compSub = _llamaParent!.completions.listen((event) {
        if (event.success) {
          if (!completer.isCompleted) completer.complete();
        } else {
          if (!completer.isCompleted) completer.complete();
        }
      });

      // send prompt
      try {
        final promptText = chatHistory.exportFormat(ChatFormat.gemma,
            leaveLastAssistantOpen: true);
        await _llamaParent!.sendPrompt(promptText);

        // wait for completion or timeout
        await completer.future.timeout(const Duration(seconds: 60),
            onTimeout: () {});
      } catch (e) {
        // fallthrough to return error
      }

      // cleanup
      await _tokenSub?.cancel();
      await _compSub?.cancel();
      _tokenSub = null;
      _compSub = null;

      final result = buffer.toString().trim();
      return result.isEmpty
          ? 'Erro: modelo local não retornou texto.'
          : result;
    }

    // Fallback: call remote Ollama-compatible HTTP endpoint (useful for desktop testing)
    const url = 'http://127.0.0.1:11434/v1/chat/completions';
    final payload = {
      'model': 'gemma3:1b',
      'messages': [
        {
          'role': 'system',
          'content': systemPrompt,
        },
        {
          'role': 'user',
          'content': prompt,
        },
      ],
      'max_tokens': 256,
    };

    final http.Response response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      return 'Erro: não foi possível conectar ao Ollama. Verifique se o servidor está rodando em localhost:11434.';
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      return 'Erro: resposta inesperada do Ollama.';
    }

    final message = choices.first['message'] as Map<String, dynamic>?;
    return message?['content']?.toString() ?? 'Erro: resposta vazia.';
  }

  Future<void> _initLocalModel(String modelPath) async {
    if (_llamaParent != null) return;
    setState(() {
      _modelLoading = true;
    });

    // Assume the native llama shared library is available as 'libllama.so' in app
    Llama.libraryPath = 'libllama.so';

    // Our bundled libllama.so is compiled CPU-only (no Vulkan/OpenCL/CUDA
    // backend). The package's ModelParams() defaults (splitMode = none,
    // mainGpu = 0) make llama.cpp validate `main_gpu` against the number
    // of registered GPU devices, which is 0 on a CPU-only build, causing
    // "invalid value for main_gpu: 0 (available devices: 0)" and an
    // immediate load failure. Setting mainGpu = -1 and nGpuLayers = 0
    // makes llama.cpp skip that check and run fully on CPU.
    final modelParams = ModelParams()
      ..nGpuLayers = 0
      ..mainGpu = -1;

    final loadCommand = LlamaLoad(
      path: modelPath,
      modelParams: modelParams,
      contextParams: ContextParams(),
      samplingParams: SamplerParams(),
    );

    final parent = LlamaParent(loadCommand);
    try {
      await parent.init();
    } catch (e) {
      setState(() {
        _modelLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erro ao inicializar modelo local: $e')));
      return;
    }

    setState(() {
      _llamaParent = parent;
      _modelLoading = false;
    });
  }

  void _clearConversation() {
    setState(() {
      _messages.clear();
    });
  }

  Future<void> _signOut() async {
    await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();
  }

  @override
  void dispose() {
    _tokenSub?.cancel();
    _compSub?.cancel();
    _llamaParent?.dispose();
    _rag.dispose();
    _stt.dispose();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  /// Starts or stops microphone recording when the mic button is tapped.
  /// On stop, the recorded audio is transcribed on-device with Whisper
  /// Tiny and the result is placed in the text field for the user to
  /// review/edit before sending (rather than auto-sending), since a tiny
  /// STT model can mishear domain terms like insulin brand names.
  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final path = await _audioRecorder.stop();
      _recordingTimer?.cancel();
      setState(() {
        _isRecording = false;
        _recordingElapsed = Duration.zero;
        _isTranscribing = path != null;
      });
      if (path != null && mounted) {
        String text = '';
        try {
          text = await _stt.transcribeWavFile(path);
        } catch (_) {
          // Ignore; handled below via empty result.
        }
        if (!mounted) return;
        setState(() {
          _isTranscribing = false;
          if (text.isNotEmpty) {
            _controller.text = text;
          }
        });
        if (text.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Não consegui entender o áudio. Tente novamente ou digite '
                'sua mensagem.',
              ),
            ),
          );
        }
      }
      return;
    }

    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Permissão de microfône negada.'),
          ),
        );
      }
      return;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/diabot_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    setState(() {
      _isRecording = true;
      _recordingElapsed = Duration.zero;
    });
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordingElapsed += const Duration(seconds: 1));
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// Replaces the text field while recording, showing a pulsing mic icon
  /// and elapsed time instead of a keyboard.
  Widget _buildRecordingIndicator() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record,
              color: Theme.of(context).colorScheme.error, size: 14),
          const SizedBox(width: 8),
          const Text('Gravando...'),
          const Spacer(),
          Text(_formatDuration(_recordingElapsed)),
        ],
      ),
    );
  }

  /// Shown briefly after recording stops, while Whisper Tiny transcribes
  /// the audio on-device.
  Widget _buildTranscribingIndicator() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: const [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('Transcrevendo...'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diabot'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_download_outlined),
            onPressed: () async {
              final controller = TextEditingController(
                  text: '/sdcard/Download/gemma-3-1b-it-Q4_0.gguf');
              final path = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Inicializar modelo local'),
                  content: TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                        labelText: 'Caminho do modelo no dispositivo'),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop(null),
                        child: const Text('Cancelar')),
                    ElevatedButton(
                        onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                        child: const Text('Iniciar')),
                  ],
                ),
              );

              if (path != null && path.isNotEmpty) {
                await _initLocalModel(path);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(_llamaParent != null
                      ? 'Modelo local inicializado.'
                      : 'Falha ao inicializar modelo.'),
                ));
              }
            },
            tooltip: 'Inicializar modelo local',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _messages.isEmpty ? null : _clearConversation,
            tooltip: 'Limpar conversa',
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: _editProfile,
            tooltip: 'Editar perfil',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
            tooltip: 'Sair',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                final isUser = message.role == 'user';
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  alignment:
                      isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isUser
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      message.text,
                      style: TextStyle(
                        color: isUser
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: _isRecording
                      ? _buildRecordingIndicator()
                      : _isTranscribing
                          ? _buildTranscribingIndicator()
                          : TextField(
                              controller: _controller,
                              decoration: const InputDecoration(
                                hintText:
                                    'Digite sua pergunta sobre diabetes...',
                                border: OutlineInputBorder(),
                              ),
                              minLines: 1,
                              maxLines: 4,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _sendMessage(),
                            ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed:
                      (_isLoading || _isTranscribing) ? null : _toggleRecording,
                  style: _isRecording
                      ? IconButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.errorContainer,
                        )
                      : null,
                  icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                  tooltip: _isRecording
                      ? 'Parar grava\u00e7\u00e3o'
                      : 'Gravar mensagem de voz',
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: (_isLoading || _isRecording || _isTranscribing)
                      ? null
                      : _sendMessage,
                  child: const Text('Enviar'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
