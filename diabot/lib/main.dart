import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'events.dart';
import 'local_db.dart';
import 'login_page.dart';
import 'nlu.dart';
import 'onboarding_page.dart';
import 'orchestrator.dart';
import 'rag.dart';
import 'stt.dart';
import 'user_profile.dart';

const _kLastBuildNumberKey = 'diabot_last_build_number';

/// Default on-device model file. It must be placed manually on the device
/// (e.g. copied via USB or downloaded through the phone's browser) at this
/// exact path — the app never fetches it over the network. Using the base
/// (pretrained-only, non-instruction-tuned) Gemma 3 4B checkpoint here per
/// request. Gemma 3 4B needs ~2.5GB of RAM/storage and is noticeably
/// slower per classification than the 1B model. If the file is missing,
/// `_initLocalModel` fails fast with a clear SnackBar instead of hanging,
/// so it's safe to leave this pointed at 4B even before the file is
/// copied over.
///
/// NOTE: this model is intentionally NOT auto-loaded at startup anymore.
/// Loading a 2.36GB model natively while the STT (Whisper) and RAG
/// (embedding) models are also loading concurrently caused a native
/// out-of-memory crash on a mid-range device (Galaxy A56) — a crash that
/// Dart's try/catch cannot intercept because it happens inside the native
/// llama.cpp/mmap code, not in Dart. Use the cloud-download icon in the
/// app bar to load it manually once the app is idle.
const _defaultModelPath = '/sdcard/Download/gemma-3-4b-Q4_0.gguf';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Modern edge-to-edge display: the status/navigation bars stay visible
  // (rather than being hidden until a swipe), and app content is drawn
  // behind them — Scaffolds below add bottom SafeArea padding so content
  // never sits underneath the Android nav buttons.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
  await LocalDatabase.instance.clearAll();
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
  // Optional tappable quick-reply options attached to an assistant message
  // (e.g. "Sim" / "Não", "Leve" / "Moderada" / "Intensa"). Tapping one
  // feeds its label back through the same pipeline as typed/voice input.
  final List<String>? quickReplies;
  // Optional hint label for a numeric data-entry field shown instead of
  // (or alongside) quick replies, when the orchestrator's next question
  // expects a value (grams of carbs, a glucose reading, insulin units).
  final String? numericInputHint;

  Message(this.role, this.text, {this.quickReplies, this.numericInputHint});
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
  // "Gemma listens, DIABOT talks": Gemma is only ever asked to extract
  // events + fields (see nlu.dart). All user-facing text comes from
  // ConversationOrchestrator's fixed template responses, except the one
  // FSM-approved exception (a `question` event resolved via RAG lookup in
  // `_answerEducationQuestion` below). Every completed event is persisted
  // to the local SQLite event log.
  late final ConversationOrchestrator _orchestrator = ConversationOrchestrator(
    storeGateway: LocalDatabase.instance,
    onEducationRequest: _answerEducationQuestion,
    emergencyEngine: EmergencyEngine(history: LocalDatabase.instance),
  );

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
    _loadProfile().then((_) async {
      // Loaded sequentially (not concurrently) to avoid piling up several
      // large native allocations (RAG embeddings + Whisper STT + Gemma)
      // at the exact same moment, which previously caused a native
      // out-of-memory crash on startup. Each one is still best-effort:
      // a failure here doesn't block the app, it just disables that
      // feature until retried.
      //
      // Loads the on-device embedding model + knowledge base. If it
      // fails (e.g. low storage), RAG context is simply skipped and the
      // chat still works with the base system prompt.
      await _rag.ensureInitialized().catchError((_) {});
      // Loads the on-device Whisper Tiny STT model, forcing decoding to
      // the user's known language (from onboarding / device locale) so
      // it doesn't randomly guess Portuguese, English, or Russian per
      // recording. If it fails, the mic button will simply show an
      // error when tapped.
      await _stt
          .ensureInitialized(language: _profile.idioma)
          .catchError((_) {});
      // The local Gemma 4B model is intentionally NOT auto-loaded here —
      // see the doc comment on `_defaultModelPath` for why. Load it via
      // the cloud-download icon in the app bar when ready.
    });
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

  /// Sends [forcedText] (a tapped quick-reply label) or, if omitted, the
  /// current contents of the text field. Both typed/transcribed text and
  /// quick-reply taps go through the exact same orchestrator pipeline.
  Future<void> _sendMessage([String? forcedText]) async {
    final prompt = forcedText ?? _controller.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _messages.add(Message('user', prompt));
      if (forcedText == null) _controller.clear();
      _isLoading = true;
    });

    final reply = await _getOrchestratorReply(prompt);

    setState(() {
      _messages.add(
        Message('assistant', reply.text, quickReplies: reply.quickReplies),
      );
      _isLoading = false;
    });
  }

  /// Routes [prompt] through the on-device event parser + the FSM
  /// (`ConversationOrchestrator`). Gemma never generates the text shown to
  /// the user directly — see nlu.dart / orchestrator.dart.
  Future<OrchestratorReply> _getOrchestratorReply(String prompt) async {
    final parent = _llamaParent;
    final classifier = parent != null && parent.status == LlamaStatus.ready
        ? IntentClassifier(parent)
        : null;
    return _orchestrator.respond(prompt, classifier);
  }

  /// The FSM's single approved exception: a `question` event delegates
  /// here for a free-text answer. The loaded model's sampler is fixed to
  /// the classifier's JSON grammar for its whole lifetime (see
  /// `_initLocalModel`), so it cannot also generate free text — this
  /// returns the most relevant retrieved knowledge instead of an LLM
  /// generation until a separate, non-grammar-constrained model path
  /// exists for education answers.
  Future<String> _answerEducationQuestion(String question) async {
    final chunks = await _rag.retrieve(question);
    if (chunks.isEmpty) {
      return 'Ainda não tenho uma resposta para isso.';
    }
    return chunks.first;
  }

  Future<void> _initLocalModel(String modelPath) async {
    if (_llamaParent != null) return;

    // Android's scoped storage blocks native mmap/open() access to
    // /sdcard paths unless "All files access" is granted — a special
    // app-op the user must toggle in system Settings, it cannot be
    // granted via a normal permission dialog. Without it, Dart-level
    // `existsSync()` can still succeed while llama.cpp's native file open
    // fails with an opaque LlamaException, so this must be checked first.
    if (!await Permission.manageExternalStorage.isGranted) {
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'É preciso conceder "Acesso a todos os arquivos" ao Diabot '
                  'para carregar o modelo local. Conceda a permissão e tente '
                  'novamente.')));
        }
        return;
      }
    }

    // Fail fast with a clear message if the gguf simply isn't on the
    // device yet, instead of letting llama.cpp try to mmap a missing/huge
    // path natively, which can hang the UI thread and appear to crash.
    if (!File(modelPath).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Modelo não encontrado em $modelPath. Copie o arquivo '
                '.gguf para essa pasta no dispositivo antes de continuar.')));
      }
      return;
    }

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

    // The multi-event few-shot system prompt (see IntentClassifier) is
    // ~1200 tokens on its own — nCtx must comfortably exceed prompt +
    // user text + generated JSON, or the model has zero room left to
    // generate anything and silently returns an empty completion (this
    // previously caused every message to fall back to "unknown", not a
    // parsing bug). nPredict caps generation length so a rambling
    // completion can't run on indefinitely.
    final contextParams = ContextParams()
      ..nCtx = 2048
      ..nBatch = 256
      ..nUbatch = 256
      ..nPredict = 200;

    // Greedy + grammar-constrained: this model only ever does structured
    // JSON extraction (never free-form chat), so deterministic decoding
    // constrained to IntentClassifier.grammar is faster than sampling and
    // guarantees valid, parseable output every time.
    final samplerParams = SamplerParams()
      ..greedy = true
      ..grammarStr = IntentClassifier.grammar
      ..grammarRoot = 'root';

    final loadCommand = LlamaLoad(
      path: modelPath,
      modelParams: modelParams,
      contextParams: contextParams,
      samplingParams: samplerParams,
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
              final controller = TextEditingController(text: _defaultModelPath);
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
                final isLastAssistantMessage = !isUser &&
                    !_isLoading &&
                    index == _messages.length - 1;
                final showQuickReplies = isLastAssistantMessage &&
                    (message.quickReplies?.isNotEmpty ?? false);
                final showNumericInput =
                    isLastAssistantMessage && message.numericInputHint != null;
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: isUser
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Align(
                        alignment: isUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isUser
                                ? Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            message.text,
                            style: TextStyle(
                              color: isUser
                                  ? Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      if (showQuickReplies)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final option in message.quickReplies!)
                                ActionChip(
                                  label: Text(option),
                                  onPressed: () => _sendMessage(option),
                                ),
                            ],
                          ),
                        ),
                      if (showNumericInput)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: SizedBox(
                            width: 260,
                            child: _NumericInputRow(
                              hint: message.numericInputHint!,
                              onSubmit: _sendMessage,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_modelLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Carregando modelo local...'),
                ],
              ),
            ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
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
                                      'Escreva aqui ou clique no microfone '
                                      'para falar',
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
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// A small numeric text entry + send button, shown under the last
/// assistant message when [ConversationOrchestrator] expects a data value
/// (grams of carbs, a glucose reading, insulin units) rather than a fixed
/// choice. Submitting feeds the typed value through the same
/// `_sendMessage` pipeline as regular typed/voice/quick-reply input.
class _NumericInputRow extends StatefulWidget {
  final String hint;
  final ValueChanged<String> onSubmit;

  const _NumericInputRow({required this.hint, required this.onSubmit});

  @override
  State<_NumericInputRow> createState() => _NumericInputRowState();
}

class _NumericInputRowState extends State<_NumericInputRow> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              isDense: true,
              hintText: widget.hint,
              border: const OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          onPressed: _submit,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }
}
