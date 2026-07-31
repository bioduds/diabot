import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'events.dart';
import 'local_db.dart';
import 'login_page.dart';
import 'llm_runtime.dart';
import 'module_catalog.dart';
import 'nlu.dart';
import 'orchestrator.dart';
import 'profile_engine.dart';
import 'profile_view.dart';
import 'rag.dart';
import 'stt.dart';
import 'time_engine.dart';
import 'ui_text.dart';
import 'user_profile.dart';
import 'semantic_diagnostics.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Default on-device model file. It must be placed manually on the device
/// (e.g. copied via USB or downloaded through the phone's browser) at this
/// exact path — the app never fetches it over the network. Using Gemma 4
/// E4B in `.litertlm` format (LiteRT-LM runtime, via `flutter_gemma` +
/// `flutter_gemma_litertlm`), replacing the previous `llama_cpp_dart`/GGUF
/// backend, whose isolate-based generation crashed with "Cannot invoke
/// native callback from a different isolate". The file is ~3.66GB on disk;
/// if it's missing, `_initLocalModel` fails fast with a clear SnackBar
/// instead of hanging.
///
/// NOTE: this model is intentionally NOT auto-loaded at startup. Loading a
/// multi-GB model natively while the STT (Whisper) and RAG (embedding)
/// models are also loading concurrently caused a native out-of-memory
/// crash on a mid-range device (Galaxy A56) — a crash that Dart's
/// try/catch cannot intercept because it happens inside the native model
/// runtime/mmap code, not in Dart. Use the cloud-download icon in the app
/// bar to load it manually once the app is idle.
const _defaultModelPath = '/sdcard/Download/gemma-4-E4B-it.litertlm';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Modern edge-to-edge display: the status/navigation bars stay visible
  // (rather than being hidden until a swipe), and app content is drawn
  // behind them — Scaffolds below add bottom SafeArea padding so content
  // never sits underneath the Android nav buttons.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Registers the LiteRT-LM engine once for the process; must run before
  // any `FlutterGemma.installModel(...)`/`getActiveModel(...)` call.
  await FlutterGemma.initialize(inferenceEngines: [const LiteRtLmEngine()]);
  await Firebase.initializeApp();
  await UiText.load(
    WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
  );
  runApp(const DiabotApp());
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

/// Shows [LoginPage] when signed out and [ChatPage] when signed in.
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

/// Starts [ChatPage] after authentication. The chat FSM receives the
/// first-login onboarding entry point only when no [UserProfile] is saved.
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
    return ChatPage(startOnboarding: _onboardingComplete == false);
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, this.startOnboarding = false});

  final bool startOnboarding;

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

enum _InteractionMode { free, guided }

class _GuidedPrompt {
  const _GuidedPrompt({
    required this.moduleId,
    required this.kind,
    required this.question,
    this.options = const [],
    this.numericInputHint,
  });

  final String moduleId;
  final FieldKind kind;
  final String question;
  final List<String> options;
  final String? numericInputHint;
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _controller = TextEditingController();
  final List<Message> _messages = [];
  bool _isLoading = false;
  _InteractionMode _interactionMode = _InteractionMode.free;
  _GuidedPrompt? _guidedPrompt;
  final Talker _talker = Talker();
  late final SemanticDiagnostics _semanticDiagnostics =
      SemanticDiagnostics(_talker);
  // On-device language-model runtime and semantic interpreter.
  LocalLLMRuntime? _llmRuntime;
  IntentClassifier? _semanticInterpreter;
  bool _modelLoading = false;
  bool _isBootstrapping = true;
  String? _bootstrapError;
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
    emergencyEngine: EmergencyEngine(
      history: LocalDatabase.instance,
      temporalContextProvider: TimeEngine(history: LocalDatabase.instance),
    ),
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
    _bootstrapAfterLogin();
  }

  Future<void> _bootstrapAfterLogin() async {
    setState(() {
      _isBootstrapping = true;
      _bootstrapError = null;
    });
    final profile = await _loadProfileWithAuthenticatedIdentity();
    final modelReady = await _initLocalModel(
      _defaultModelPath,
      showError: false,
    );
    if (!modelReady) {
      if (mounted) {
        setState(() {
          _isBootstrapping = false;
          _bootstrapError = 'Não foi possível carregar o modelo local.';
        });
      }
      return;
    }

    OrchestratorReply? onboardingReply;
    if (widget.startOnboarding) {
      onboardingReply = await _orchestrator.beginOnboarding(
        profile: profile,
        deviceLanguage:
            WidgetsBinding.instance.platformDispatcher.locale.languageCode,
        accountDisplayName: FirebaseAuth.instance.currentUser?.displayName,
      );
    }
    if (!mounted) return;
    setState(() {
      _isBootstrapping = false;
      if (onboardingReply != null) {
        _messages.add(Message(
          'assistant',
          onboardingReply.text,
          quickReplies: onboardingReply.quickReplies,
        ));
        _guidedPrompt = _GuidedPrompt(
          moduleId: onboardingReply.guidedModuleId ?? 'onboarding',
          kind: onboardingReply.guidedFieldKind ?? FieldKind.freeText,
          question: onboardingReply.text,
          options: onboardingReply.quickReplies ?? const [],
          numericInputHint: onboardingReply.numericInputHint,
        );
        _interactionMode = _InteractionMode.guided;
      }
    });

    // These smaller local models begin only after the external GGUF is
    // ready, avoiding concurrent native model initialization.
    await _rag.ensureInitialized().catchError((_) {});
    await _stt.ensureInitialized(language: profile.idioma).catchError((_) {});
  }

  Future<UserProfile> _loadProfileWithAuthenticatedIdentity() async {
    final profile = await UserProfile.load();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return profile;

    var changed = false;
    void fillIfEmpty(
        String current, String? authenticated, void Function(String) set) {
      final value = authenticated?.trim() ?? '';
      if (current.isNotEmpty || value.isEmpty) return;
      set(value);
      changed = true;
    }

    fillIfEmpty(
        profile.nome, user.displayName, (value) => profile.nome = value);
    fillIfEmpty(profile.email, user.email, (value) => profile.email = value);
    fillIfEmpty(
        profile.fotoUrl, user.photoURL, (value) => profile.fotoUrl = value);
    if (changed) await profile.save();
    return profile;
  }

  /// Sends [forcedText] (a tapped quick-reply label) or, if omitted, the
  /// current contents of the text field. Both typed/transcribed text and
  /// quick-reply taps go through the exact same orchestrator pipeline.
  Future<void> _sendMessage([String? forcedText, bool fromGuided = false]) async {
    if (_isBootstrapping) return;
    final prompt = forcedText ?? _controller.text.trim();
    if (prompt.isEmpty) return;

    if (!fromGuided && forcedText == null && _semanticInterpreter == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'O interpretador local não foi inicializado.',
        ),
      ));
      return;
    }

    setState(() {
      _messages.add(Message('user', prompt));
      if (!fromGuided && forcedText == null) _controller.clear();
      _isLoading = true;
    });

    final reply = await _getOrchestratorReply(prompt);
    if (!mounted) return;
    _presentReply(reply);
  }

  Future<void> _sendGuidedValue(String value) =>
      _sendMessage(value, true);

  Future<void> _exitGuidedMode() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    final reply = await _orchestrator.exitGuidedMode();
    if (!mounted) return;
    _presentReply(reply);
  }

  void _presentReply(OrchestratorReply reply) {
    final guidedKind = reply.guidedFieldKind;
    setState(() {
      if (guidedKind == null) {
        _messages.add(
          Message('assistant', reply.text, quickReplies: reply.quickReplies),
        );
      }
      _guidedPrompt = guidedKind == null
          ? null
          : _GuidedPrompt(
              moduleId: reply.guidedModuleId ?? 'event-context',
              kind: guidedKind,
              question: reply.text,
              options: reply.quickReplies ?? const [],
              numericInputHint: reply.numericInputHint,
            );
      _interactionMode =
          guidedKind == null ? _InteractionMode.free : _InteractionMode.guided;
      _isLoading = false;
    });
  }

  /// Routes [prompt] through the on-device event parser + the FSM
  /// (`ConversationOrchestrator`). Gemma never generates the text shown to
  /// the user directly — see nlu.dart / orchestrator.dart.
  Future<OrchestratorReply> _getOrchestratorReply(String prompt) async {
    return _orchestrator.respond(prompt, _semanticInterpreter);
  }

  /// The FSM's single approved exception: a `question` event delegates
  /// here for a free-text answer. Per AGENTS.md, the on-device LLM's only
  /// job is structured extraction (see `nlu.dart`), so education answers
  /// are served from retrieved knowledge instead of a free-text LLM
  /// generation — this is an architecture boundary, not a technical
  /// limitation of the current backend.
  Future<String> _answerEducationQuestion(String question) async {
    final chunks = await _rag.retrieve(question);
    if (chunks.isEmpty) {
      return 'Ainda não tenho uma resposta para isso.';
    }
    return chunks.first;
  }

  Future<bool> _initLocalModel(
    String modelPath, {
    bool showError = true,
  }) async {
    if (_llmRuntime?.status == LLMStatus.ready) return true;
    if (_llmRuntime != null) {
      await _llmRuntime!.dispose();
      if (mounted) {
        setState(() {
          _llmRuntime = null;
          _semanticInterpreter = null;
        });
      }
    }
    if (_modelLoading) return false;

    // Android's scoped storage blocks native mmap/open() access to
    // /sdcard paths unless "All files access" is granted — a special
    // app-op the user must toggle in system Settings, it cannot be
    // granted via a normal permission dialog. Without it, Dart-level
    // `existsSync()` can still succeed while the native model file open
    // fails with an opaque error, so this must be checked first.
    if (!await Permission.manageExternalStorage.isGranted) {
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        if (showError && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'É preciso conceder "Acesso a todos os arquivos" ao Diabot '
                  'para carregar o modelo local. Conceda a permissão e tente '
                  'novamente.')));
        }
        return false;
      }
    }

    // Fail fast with a clear message if the model file simply isn't on
    // the device yet, instead of letting the native runtime map a
    // missing/huge path natively, which can hang the UI thread and appear
    // to crash.
    if (!File(modelPath).existsSync()) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Modelo não encontrado em $modelPath. Copie o arquivo '
                '.litertlm para essa pasta no dispositivo antes de continuar.')));
      }
      return false;
    }

    setState(() {
      _modelLoading = true;
    });

    // The runtime owns native configuration and keeps this UI independent
    // from the LiteRT-LM backend implementation.
    try {
      final runtime = await LocalLLMRuntime.load(modelPath: modelPath);
      if (!mounted) {
        await runtime.dispose();
        return false;
      }
      setState(() {
        _llmRuntime = runtime;
        _semanticInterpreter = IntentClassifier(
          runtime,
          diagnostics: _semanticDiagnostics,
        );
        _modelLoading = false;
      });
      return true;
    } catch (e) {
      setState(() {
        _modelLoading = false;
      });
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Erro ao inicializar modelo local: $e')));
      }
      return false;
    }

  }

  void _clearConversation() {
    setState(() {
      _messages.clear();
    });
  }

  void _showSemanticDiagnostics() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ValueListenableBuilder<SemanticDebugSnapshot?>(
            valueListenable: _semanticDiagnostics.latest,
            builder: (context, snapshot, _) {
              final data = snapshot;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.bug_report_outlined),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Diagnóstico da interpretação',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Fechar',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    data?.summary ??
                        'Nenhuma mensagem em modo livre foi interpretada nesta sessão.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  _DiagnosticLine(
                    label: 'Modelo local',
                    value: _llmRuntime?.status.name ?? 'não inicializado',
                  ),
                  _DiagnosticLine(
                    label: 'Etapa',
                    value: data?.stage ?? 'sem execução',
                  ),
                  _DiagnosticLine(
                    label: 'Saída do modelo',
                    value: data == null
                        ? 'sem execução'
                        : '${data.outputCharacters} caracteres',
                  ),
                  _DiagnosticLine(
                    label: 'JSON estruturado',
                    value: data?.hasJson == null
                        ? 'não avaliado'
                        : data!.hasJson!
                            ? 'sim'
                            : 'não',
                  ),
                  _DiagnosticLine(
                    label: 'Eventos detectados',
                    value: data == null || data.eventNames.isEmpty
                        ? 'nenhum'
                        : data.eventNames.join(', '),
                  ),
                  _DiagnosticLine(
                    label: 'Confiança',
                    value: data?.confidence?.toStringAsFixed(2) ?? 'não disponível',
                  ),
                  if (data?.timedOut == true)
                    const _DiagnosticLine(
                      label: 'Tempo limite',
                      value: 'a geração excedeu 30 segundos',
                    ),
                  if (data?.failure != null)
                    _DiagnosticLine(
                      label: 'Erro nativo',
                      value: data!.failure!,
                      isError: true,
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Este painel não armazena nem mostra o texto digitado ou a resposta bruta do modelo.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.list_alt_outlined),
                    label: const Text('Ver histórico técnico'),
                    onPressed: () => Navigator.of(sheetContext).push(
                      MaterialPageRoute(
                        builder: (_) => TalkerScreen(
                          talker: _talker,
                          appBarTitle: 'Histórico técnico',
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _clearDebugData() async {
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Apagar dados de teste?'),
        content: const Text(
          'Isso apaga perfil, eventos, auditoria e sessão local deste dispositivo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_forever),
            label: const Text('Apagar'),
          ),
        ],
      ),
    );
    if (shouldClear != true) return;

    await LocalDatabase.instance.clearAll();
    final preferences = await SharedPreferences.getInstance();
    await preferences.clear();
    await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();
  }

  Future<void> _signOut() async {
    await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();
  }

  @override
  void dispose() {
    _llmRuntime?.dispose();
    _semanticDiagnostics.dispose();
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

  Widget _buildBootstrapBody() {
    final error = _bootstrapError;
    if (error == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Carregando modelo local...'),
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            const Text(
              'Verifique o arquivo .litertlm e a permissão de acesso a todos os arquivos.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _bootstrapAfterLogin,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diabot'),
        actions: [
          if (kDebugMode)
            IconButton(
              icon: const Icon(Icons.bug_report_outlined),
              onPressed: _showSemanticDiagnostics,
              tooltip: 'Diagnóstico da interpretação',
            ),
          if (kDebugMode)
            IconButton(
              icon: const Icon(Icons.delete_forever_outlined),
              onPressed: _clearDebugData,
              tooltip: 'Apagar dados de teste',
            ),
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
                        onPressed: () =>
                            Navigator.of(ctx).pop(controller.text.trim()),
                        child: const Text('Iniciar')),
                  ],
                ),
              );

              if (path != null && path.isNotEmpty) {
                await _initLocalModel(path);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(_llmRuntime != null
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
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProfileViewPage(
                profileEngine: ProfileEngine(
                  snapshotGateway: LocalDatabase.instance,
                ),
              ),
            )),
            tooltip: 'Ver perfil',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
            tooltip: 'Sair',
          ),
        ],
      ),
      body: _isBootstrapping || _bootstrapError != null
          ? _buildBootstrapBody()
          : Column(
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
                _interactionMode == _InteractionMode.guided &&
                        _guidedPrompt != null
                    ? SafeArea(
                        top: false,
                        child: _GuidedInputPanel(
                          key: ValueKey(_guidedPrompt!.question),
                          prompt: _guidedPrompt!,
                          isLoading: _isLoading,
                          onSubmit: _sendGuidedValue,
                          onExit: _exitGuidedMode,
                        ),
                      )
                    : _buildFreeInput(),
                const SizedBox(height: 8),
              ],
            ),
    );
  }

  Widget _buildFreeInput() {
    return SafeArea(
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
                                'Escreva aqui ou clique no microfone para falar',
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
              onPressed: (_isLoading || _isTranscribing)
                  ? null
                  : _toggleRecording,
              style: _isRecording
                  ? IconButton.styleFrom(
                      backgroundColor:
                          Theme.of(context).colorScheme.errorContainer,
                    )
                  : null,
              icon: Icon(_isRecording ? Icons.stop : Icons.mic),
              tooltip: _isRecording ? 'Parar gravação' : 'Gravar mensagem de voz',
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
    );
  }
}

class _DiagnosticLine extends StatelessWidget {
  const _DiagnosticLine({
    required this.label,
    required this.value,
    this.isError = false,
  });

  final String label;
  final String value;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? Theme.of(context).colorScheme.error : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.bodyMedium,
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }
}

/// The only input surface shown while the FSM is collecting a field or
/// context. It submits deterministic control values directly to the Kernel;
/// it never sends this data through the free-text semantic interpreter.
class _GuidedInputPanel extends StatefulWidget {
  const _GuidedInputPanel({
    super.key,
    required this.prompt,
    required this.isLoading,
    required this.onSubmit,
    required this.onExit,
  });

  final _GuidedPrompt prompt;
  final bool isLoading;
  final ValueChanged<String> onSubmit;
  final VoidCallback onExit;

  @override
  State<_GuidedInputPanel> createState() => _GuidedInputPanelState();
}

class _GuidedInputPanelState extends State<_GuidedInputPanel> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.isLoading) return;
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    final usesOptions = prompt.options.isNotEmpty;
    final numeric = prompt.kind == FieldKind.number;
    final module = GuidedModuleCatalog.byId(prompt.moduleId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(module.icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  UiText.current.get(module.titleKey),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: widget.isLoading ? null : widget.onExit,
                icon: const Icon(Icons.close),
                label: Text(UiText.current.get('guided.exit')),
              ),
            ],
          ),
          if (usesOptions)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in prompt.options)
                  OutlinedButton(
                    onPressed: widget.isLoading
                        ? null
                        : () => widget.onSubmit(option),
                    child: Text(option),
                  ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    keyboardType: numeric
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : TextInputType.text,
                    decoration: InputDecoration(
                        hintText: prompt.numericInputHint ??
                          UiText.current.get('guided.inputHint'),
                      border: const OutlineInputBorder(),
                    ),
                    minLines: numeric ? 1 : 1,
                    maxLines: numeric ? 1 : 3,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: widget.isLoading ? null : _submit,
                  icon: const Icon(Icons.send),
                  tooltip: UiText.current.get('guided.submitTooltip'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
