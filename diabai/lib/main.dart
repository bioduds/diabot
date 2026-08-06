import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'app_theme.dart';
import 'cgm/past_event_interpreter.dart';
import 'cgm_sync_engine.dart';
import 'events.dart';
import 'glucose_chart.dart';
import 'glucose_time_picker.dart';
import 'librelinkup.dart';
import 'local_db.dart';
import 'login_page.dart';
import 'llm_runtime.dart';
import 'module_catalog.dart';
import 'nlu.dart';
import 'orchestrator.dart';
import 'rag.dart';
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
  runApp(const DiabAIApp());
}

class DiabAIApp extends StatelessWidget {
  const DiabAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DiabAI',
      theme: diabAITheme,
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
    return HomeShell(startOnboarding: _onboardingComplete == false);
  }
}

/// The app's home shell once signed in: [GlucoseChartPage] is always the
/// backdrop, with the Nuno [ChatPage] embedded as a panel that slides up
/// over it. During first-run onboarding the panel starts expanded (so the
/// conversation that collects the initial profile data is what the user
/// sees) and automatically slides back down to reveal Glicemia as the
/// main screen once onboarding finishes. If onboarding was already done
/// in a previous session, Glicemia loads directly with the chat collapsed.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.startOnboarding});

  final bool startOnboarding;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// What the post-onboarding gate in [_HomeShellState] should show instead
/// of the normal glucose chart, per AGENTS.md item 6: `none` proceeds
/// straight to [GlucoseChartPage] (the default/only state for anyone who
/// isn't set up with a linked LibreLinkUp account), `syncing` is a
/// transitional "Obtendo leituras do CGM" screen shown while the very
/// first sync after onboarding runs, and `failed` explains that no
/// reading arrived yet and offers "Continuar sem CGM" or a retry that
/// resumes the actual CGM connection sub-step (not just a blind re-poll).
enum _PostOnboardingCgmStage { none, syncing, failed }

class _HomeShellState extends State<HomeShell> {
  // Follows a linked LibreLinkUp account every 60s while the app is open
  // and stores new readings as ordinary glucose events — see
  // docs/fsm/cgm.mmd. A no-op (cheap secure-storage read) until onboarding
  // connects an account. Shared between the Glicemia backdrop and the
  // embedded chat's onboarding flow.
  final CgmSyncEngine _cgmSyncEngine = CgmSyncEngine(
    credentialStore: LibreLinkUpCredentialStore(),
    storeGateway: LocalDatabase.instance,
  );

  final GlobalKey<_ChatPageState> _chatKey = GlobalKey<_ChatPageState>();
  late bool _chatExpanded = widget.startOnboarding;
  // Unlike widget.startOnboarding (fixed for HomeShell's lifetime), this
  // flips to false once onboarding actually completes, so the collapse
  // button doesn't stay disabled for the rest of the session.
  late bool _onboardingActive = widget.startOnboarding;

  _PostOnboardingCgmStage _postOnboardingCgmStage = _PostOnboardingCgmStage.none;
  String? _cgmFailureReason;

  @override
  void initState() {
    super.initState();
    _cgmSyncEngine.start();
  }

  @override
  void dispose() {
    _cgmSyncEngine.stop();
    super.dispose();
  }

  void _openChat(String report) {
    _chatKey.currentState?._receiveGlucoseReport(report);
    if (!_chatExpanded) setState(() => _chatExpanded = true);
  }

  /// Tapped a Past Event Interpreter timeline marker — hands the hypothesis
  /// off to Nuno's chat panel and expands it, exactly like
  /// [_openChat]/[_receiveGlucoseReport] does for the deterministic glucose
  /// report. The chart/Timeline never converses itself; see
  /// docs/fsm/past_event_interpreter.mmd.
  void _openHypothesis(EventHypothesis hypothesis) {
    _chatKey.currentState?._receiveHypothesisPrompt(hypothesis);
    if (!_chatExpanded) setState(() => _chatExpanded = true);
  }

  void _collapseChat() {
    if (!_chatExpanded) return;
    // ChatPage stays permanently mounted (only its position animates), so
    // a focused guided-input field would otherwise keep the keyboard open
    // over the chart underneath.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _chatExpanded = false);
  }

  bool _isLibreProvider(String provider) =>
      provider.trim().toLowerCase().contains('libre');

  /// Runs once onboarding (re-)finishes — including after a CGM
  /// reconnection retry, since [_resumeCgmConnection] re-enters onboarding
  /// and naturally calls this again on completion. Decides whether to show
  /// the normal chart right away or gate it behind a "Obtendo leituras do
  /// CGM" / failure screen, per AGENTS.md item 6.
  Future<void> _handleOnboardingComplete() async {
    // Same reason as _collapseChat: the last guided question's text field
    // can still hold focus after ChatPage slides off-screen.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _chatExpanded = false;
      _onboardingActive = false;
    });
    final profile = await UserProfile.load();
    if (!mounted) return;
    if (profile.cgmUsaServico != 'sim' || !_isLibreProvider(profile.cgmProvider)) {
      // Doesn't use a CGM, or uses one we can't auto-fetch from — nothing
      // to wait for, go straight to the normal chart.
      setState(() => _postOnboardingCgmStage = _PostOnboardingCgmStage.none);
      return;
    }
    if (profile.cgmLibreLinkUpConectado != 'sim') {
      // Chose a Libre sensor but the LibreLinkUp connection itself never
      // succeeded during onboarding — nothing to fetch, skip straight to
      // the failure screen instead of attempting a sync that can't work.
      setState(() {
        _postOnboardingCgmStage = _PostOnboardingCgmStage.failed;
        _cgmFailureReason =
            'Não foi possível conectar à sua conta LibreLinkUp durante a configuração.';
      });
      return;
    }
    setState(() => _postOnboardingCgmStage = _PostOnboardingCgmStage.syncing);
    await _cgmSyncEngine.syncOnce();
    if (!mounted) return;
    final readings = await LocalDatabase.instance
        .recentEventsOfType('glucose', const Duration(hours: 24));
    if (!mounted) return;
    if (readings.isNotEmpty) {
      setState(() => _postOnboardingCgmStage = _PostOnboardingCgmStage.none);
    } else {
      setState(() {
        _postOnboardingCgmStage = _PostOnboardingCgmStage.failed;
        _cgmFailureReason =
            'Conectamos à sua conta LibreLinkUp, mas ainda não recebemos '
            'nenhuma leitura do sensor.';
      });
    }
  }

  /// "Continuar sem CGM" — dismisses the gate and shows the normal chart
  /// even though no reading arrived.
  void _continueWithoutCgm() {
    setState(() => _postOnboardingCgmStage = _PostOnboardingCgmStage.none);
  }

  /// "Tentar conectar de novo" — per AGENTS.md item 6 this must resume the
  /// actual CGM connection sub-step (asking email/password again), not
  /// just blindly re-poll. Re-expands the embedded chat so the user can
  /// answer it, then hands off to the already-built retry plumbing;
  /// [_handleOnboardingComplete] fires again once it completes.
  void _retryCgmConnection() {
    setState(() {
      _postOnboardingCgmStage = _PostOnboardingCgmStage.none;
      _chatExpanded = true;
      _onboardingActive = true;
    });
    _chatKey.currentState?._resumeCgmConnection();
  }

  @override
  Widget build(BuildContext context) {
    final chart = GlucoseChartPage(
      database: LocalDatabase.instance,
      cgmSyncEngine: _cgmSyncEngine,
      chatExpanded: _chatExpanded,
      isOnboarding: _onboardingActive,
      onOpenChat: _openChat,
      onHypothesisTap: _openHypothesis,
      // These used to live on Nuno's own app bar; relocated here so that
      // bar could be decluttered down to just the avatar/status/collapse.
      onShowDiagnostics: () => _chatKey.currentState?._showSemanticDiagnostics(),
      onInitModel: () => _chatKey.currentState?._promptInitModel(),
      onClearConversation: () => _chatKey.currentState?._clearConversation(),
      onSignOut: () => _chatKey.currentState?._signOut(),
      hasChatMessages: () => _chatKey.currentState?.hasMessages ?? false,
      chatOverlay: ChatPage(
        key: _chatKey,
        startOnboarding: widget.startOnboarding,
        embedded: true,
        isExpanded: _chatExpanded,
        onCollapse: _onboardingActive ? null : _collapseChat,
        onOnboardingComplete: _handleOnboardingComplete,
      ),
    );
    if (_postOnboardingCgmStage == _PostOnboardingCgmStage.none) return chart;
    // Overlaid (not swapped in) so the embedded ChatPage/_chatKey stays
    // mounted underneath — needed for the retry button to be able to call
    // back into it.
    return Stack(
      children: [
        chart,
        Positioned.fill(
          child: _CgmConnectionGate(
            stage: _postOnboardingCgmStage,
            failureReason: _cgmFailureReason,
            onRetry: _retryCgmConnection,
            onContinue: _continueWithoutCgm,
          ),
        ),
      ],
    );
  }
}

/// Full-screen transitional/failure screen shown after onboarding while
/// [_HomeShellState._handleOnboardingComplete] is fetching (or failed to
/// fetch) the first CGM reading — see AGENTS.md item 6.
class _CgmConnectionGate extends StatelessWidget {
  const _CgmConnectionGate({
    required this.stage,
    required this.failureReason,
    required this.onRetry,
    required this.onContinue,
  });

  final _PostOnboardingCgmStage stage;
  final String? failureReason;
  final VoidCallback onRetry;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final syncing = stage == _PostOnboardingCgmStage.syncing;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  syncing ? Icons.sensors : Icons.cloud_off,
                  size: 56,
                  color: syncing ? null : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 20),
                Text(
                  syncing ? 'Obtendo leituras do CGM…' : 'Não foi possível conectar',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                if (syncing) ...[
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(),
                ] else ...[
                  const SizedBox(height: 12),
                  Text(
                    failureReason ?? 'Não recebemos nenhuma leitura do sensor.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: onRetry,
                    child: const Text('Tentar conectar de novo'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: onContinue,
                    child: const Text('Continuar sem CGM'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    this.startOnboarding = false,
    this.embedded = false,
    this.isExpanded = true,
    this.onCollapse,
    this.onOnboardingComplete,
  });

  final bool startOnboarding;

  /// True when this page is mounted as the sliding overlay panel inside
  /// [HomeShell]/[GlucoseChartPage] rather than as a full-screen route.
  /// Only changes the app bar's leading collapse button; the rest of the
  /// chat UI is identical in both modes.
  final bool embedded;

  /// True once the sliding overlay is actually on-screen. The panel itself
  /// stays permanently mounted (only animated off-screen when collapsed —
  /// see [GlucoseChartPage._buildChatOverlay]), so this flag is what lets
  /// [_GuidedInputPanel] avoid grabbing keyboard focus while invisible.
  /// Always true outside the embedded/collapsible use case.
  final bool isExpanded;

  /// Shown as a leading collapse button (only while [embedded]) so the
  /// user can retract the conversation back down over Glicemia. Null
  /// during onboarding, when the panel cannot be collapsed yet.
  final VoidCallback? onCollapse;

  /// Fired once, the moment the onboarding conversation's guided flow
  /// finishes, so [HomeShell] can slide the panel back down to reveal
  /// Glicemia as the main screen.
  final VoidCallback? onOnboardingComplete;

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
  // Path to the recorded WAV file for a voice message, kept so the user
  // can play back exactly what was sent to the model.
  final String? audioPath;
  final DateTime timestamp;

  Message(this.role, this.text,
      {this.quickReplies,
      this.numericInputHint,
      this.audioPath,
      DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
}

enum _InteractionMode { free, guided }

class _GuidedPrompt {
  const _GuidedPrompt({
    required this.moduleId,
    required this.kind,
    required this.question,
    this.options = const [],
    this.numericInputHint,
    this.unitOptions = const [],
    this.obscureInput = false,
    this.eventCreatedAt,
    this.shortTitle,
  });

  final String moduleId;
  final FieldKind kind;
  final String question;
  final List<String> options;
  final String? numericInputHint;

  /// Pre-selectable unit labels (e.g. ['kg', 'lb']) shown next to a
  /// numeric guided question. Empty when the question has no units.
  final List<String> unitOptions;

  /// True only for the LibreLinkUp password question (docs/fsm/cgm.mmd).
  final bool obscureInput;

  /// The pending event's own creation moment when [kind] is
  /// [FieldKind.time] — see [OrchestratorReply.guidedEventCreatedAt].
  final DateTime? eventCreatedAt;

  /// Short per-question header label (e.g. "Peso") — see
  /// [OrchestratorReply.guidedShortTitle]. Null falls back to the
  /// module's own title.
  final String? shortTitle;
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final List<Message> _messages = [];

  // Whether the relocated 'Limpar conversa' action (Glicemia's app bar
  // menu) should currently be enabled.
  bool get hasMessages => _messages.isNotEmpty;
  final ScrollController _scrollController = ScrollController();
  int _lastScrolledMessageCount = 0;
  bool _isLoading = false;
  _InteractionMode _interactionMode = _InteractionMode.free;
  _GuidedPrompt? _guidedPrompt;

  /// The hypothesis currently being resolved through the Sim/Corrigir/
  /// Ignorar flow started by [_receiveHypothesisPrompt], or null when no
  /// timeline conversation is in progress. See
  /// docs/fsm/past_event_interpreter.mmd.
  EventHypothesis? _pendingHypothesis;

  /// True only between tapping "Corrigir" and the user's next free-text
  /// answer, which is routed through the normal orchestrator pipeline
  /// (instead of being treated as another Sim/Corrigir/Ignorar tap).
  bool _awaitingHypothesisCorrection = false;

  /// True only while the user is looking at an already-resolved
  /// hypothesis's stored data and choosing "Está correto"/"Fazer
  /// alterações" (see [_openResolvedHypothesisReview]) — distinct from
  /// [_awaitingHypothesisCorrection], which is the fresh Corrigir flow.
  bool _reviewingResolvedHypothesis = false;

  /// The stored event id being reviewed, so "Fazer alterações" can delete
  /// the old row once its replacement finishes being logged.
  String? _reviewedEventId;

  /// Set right after a hypothesis is confirmed/corrected (or re-edited),
  /// while the resulting meal/insulin/exercise guided flow may still take
  /// several turns to actually finish and store an event — resolved in
  /// [_presentReply] once the orchestrator reports a freshly stored event,
  /// linking it back to this hypothesis (see docs/fsm/past_event_interpreter.mmd).
  EventHypothesis? _hypothesisAwaitingEventLink;
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
  // "Gemma listens, DiabAI talks": Gemma is only ever asked to extract
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
  // WAV file (<=30s, Gemma 4's native audio input limit) and sent to the
  // on-device model directly — Gemma 4 is multimodal and extracts events
  // from speech itself, so no separate speech-to-text pass is needed here
  // (see `nlu.dart` / `llm_runtime.dart`).
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  Duration _recordingElapsed = Duration.zero;
  Timer? _recordingTimer;

  // Playback of a user's own recorded voice message, so they can confirm it
  // sounds right immediately after sending it.
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingAudioPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingAudioPath = null);
    });
    _bootstrapAfterLogin();
  }

  /// Fires whenever the viewport's metrics change — in particular, when
  /// the on-screen keyboard finishes opening/closing after focus moves
  /// (e.g. the new-question autofocus in [_GuidedInputPanelState]). The
  /// keyboard can still be animating in when [_scrollToBottomIfNewMessage]
  /// already ran for the new message, leaving it partially hidden behind
  /// the panel/keyboard once the resize settles — this re-scrolls once
  /// that final layout is known.
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
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
          unitOptions: onboardingReply.unitOptions,
          obscureInput: onboardingReply.obscureNextAnswer,
          shortTitle: onboardingReply.guidedShortTitle,
        );
        _interactionMode = _InteractionMode.guided;
      }
    });

    // These smaller local models begin only after the external GGUF is
    // ready, avoiding concurrent native model initialization.
    await _rag.ensureInitialized().catchError((_) {});
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
  /// current contents of the text field. Both typed text and quick-reply
  /// taps go through the exact same orchestrator pipeline; when
  /// [audioBytes] is set (a recorded voice message), it is sent to the
  /// model directly instead of the placeholder [forcedText] shown in the
  /// chat bubble. [audioPath] is kept on the bubble so the user can play
  /// back exactly what was sent.
  Future<void> _sendMessage([
    String? forcedText,
    bool fromGuided = false,
    Uint8List? audioBytes,
    String? audioPath,
  ]) async {
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

    // The LibreLinkUp password question is the one guided field whose
    // typed answer must never be echoed back into the visible chat log.
    final displayText = _guidedPrompt?.obscureInput == true
        ? '••••••••'
        : (_guidedPrompt?.kind == FieldKind.time
            ? _formatTimeAnswer(prompt)
            : prompt);
    setState(() {
      _messages.add(Message('user', displayText, audioPath: audioPath));
      if (!fromGuided && forcedText == null) _controller.clear();
      _isLoading = true;
    });

    final reply = await _getOrchestratorReply(prompt, audioBytes: audioBytes);
    if (!mounted) return;
    _presentReply(reply);
  }

  Future<void> _sendGuidedValue(String value) {
    if (_guidedPrompt?.moduleId == 'timeline') {
      return _handleTimelineGuidedValue(value);
    }
    return _sendMessage(value, true);
  }

  /// Renders a `FieldKind.time` answer (either the literal "Agora" or an
  /// ISO-8601 datetime sent by the guided panel's time picker) as a plain
  /// `HH:mm` in the chat log instead of a raw ISO string.
  String _formatTimeAnswer(String raw) {
    if (raw.trim().toLowerCase() == 'agora') return 'Agora';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final hour = parsed.hour.toString().padLeft(2, '0');
    final minute = parsed.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _exitGuidedMode() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    final reply = await _orchestrator.exitGuidedMode();
    if (!mounted) return;
    _presentReply(reply);
  }

  void _presentReply(OrchestratorReply reply) {
    final guidedKind = reply.guidedFieldKind;
    final wasOnboarding = _guidedPrompt?.moduleId == 'onboarding';
    setState(() {
      // The reply's question/confirmation text must always reach the chat
      // log — guided mode only adds an input panel below it, it never
      // renders `reply.text` itself.
      _messages.add(
        Message('assistant', reply.text, quickReplies: reply.quickReplies),
      );
      _guidedPrompt = guidedKind == null
          ? null
          : _GuidedPrompt(
              moduleId: reply.guidedModuleId ?? 'event-context',
              kind: guidedKind,
              question: reply.text,
              options: reply.quickReplies ?? const [],
              numericInputHint: reply.numericInputHint,
              unitOptions: reply.unitOptions,
              obscureInput: reply.obscureNextAnswer,
              eventCreatedAt: reply.guidedEventCreatedAt,
              shortTitle: reply.guidedShortTitle,
            );
      _interactionMode =
          guidedKind == null ? _InteractionMode.free : _InteractionMode.guided;
      _isLoading = false;
    });
    // The onboarding guided flow just finished this turn — tell the shell
    // so it can slide the chat panel back down over Glicemia.
    if (wasOnboarding && guidedKind == null) {
      widget.onOnboardingComplete?.call();
    }
    // A confirmed/corrected Timeline hypothesis's guided flow may take
    // several turns to actually store an event — once it does (stack
    // empty, no more guided fields this turn), link it back now.
    final awaitingLink = _hypothesisAwaitingEventLink;
    if (awaitingLink != null && guidedKind == null) {
      _hypothesisAwaitingEventLink = null;
      final storedEvent = _orchestrator.lastStoredEvent;
      final storedId = storedEvent?.id;
      if (storedId != null) {
        unawaited(
          LocalDatabase.instance
              .linkHypothesisToEvent(awaitingLink.id, storedId),
        );
        // The user may have dragged the curve-picker marker to a
        // different moment than the hypothesis's own original guess — keep
        // the Timeline's duration bar/marker honest with whatever time was
        // actually confirmed (request #1).
        if (storedEvent != null) {
          unawaited(
            LocalDatabase.instance
                .realignHypothesisTiming(awaitingLink.id, storedEvent.createdAt),
          );
        }
      }
    }
  }

  /// Shows the deterministic glucose report handed over by
  /// [GlucoseChartPage]'s "Conversar com Nuno" button as a normal chat
  /// turn \u2014 it's already computed real numbers, so it's appended
  /// directly instead of round-tripping through the orchestrator.
  void _receiveGlucoseReport(String report) {
    setState(() {
      _messages.add(Message('user', 'Pedi um relatório da minha glicemia.'));
      _messages.add(Message('assistant', report));
    });
  }

  /// Re-opens the CGM connection sub-flow after onboarding already
  /// finished \u2014 called by the post-onboarding "não foi possível
  /// conectar" screen's "Tentar conectar de novo" action (see
  /// docs/fsm/cgm.mmd). Reuses the same guided-prompt mechanism as
  /// first-login onboarding, so [_presentReply] naturally calls
  /// [ChatPage.onOnboardingComplete] again once it finishes.
  Future<void> _resumeCgmConnection() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    final reply = await _orchestrator.retryCgmConnection();
    if (!mounted) return;
    _presentReply(reply);
  }

  /// Opens the Sim/Corrigir/Ignorar conversation for a Past Event
  /// Interpreter hypothesis, tapped from the Timeline (see
  /// [GlucoseChartPage.onHypothesisTap]). This is the ONLY place a
  /// hypothesis turns into a Nuno conversation \u2014 the interpreter/Timeline
  /// never converse themselves. Reuses the existing guided-prompt-bar
  /// mechanism (like every other guided module) instead of a bespoke UI.
  /// Once already resolved (confirmed/corrected), re-tapping the marker
  /// instead reviews the real stored data \u2014 see
  /// [_openResolvedHypothesisReview].
  void _receiveHypothesisPrompt(EventHypothesis hypothesis) {
    if (hypothesis.status == HypothesisStatus.confirmed ||
        hypothesis.status == HypothesisStatus.corrected) {
      _openResolvedHypothesisReview(hypothesis);
      return;
    }
    final question = '${hypothesis.explanation} Foi isso que aconteceu?';
    setState(() {
      _pendingHypothesis = hypothesis;
      _awaitingHypothesisCorrection = false;
      _reviewingResolvedHypothesis = false;
      _reviewedEventId = null;
      _messages.add(Message('assistant', question));
      _guidedPrompt = _GuidedPrompt(
        moduleId: 'timeline',
        kind: FieldKind.option,
        question: question,
        options: const ['✔️ Sim', '✏️ Corrigir', '❌ Ignorar'],
      );
      _interactionMode = _InteractionMode.guided;
    });
  }

  /// Describes what was actually logged for an already-resolved hypothesis
  /// (see [describeLoggedEvent]) and offers to keep it or redo it \u2014 see
  /// docs/fsm/past_event_interpreter.mmd. Falls back to a plain
  /// explanation with no options when there is nothing linked to review
  /// (dawnPhenomenon/stress, or a linked event that could no longer be
  /// found).
  Future<void> _openResolvedHypothesisReview(
    EventHypothesis hypothesis,
  ) async {
    final linkedId = hypothesis.linkedEventId;
    final row =
        linkedId == null ? null : await LocalDatabase.instance.eventById(linkedId);
    String description;
    List<String> options = const [];
    if (row == null) {
      description = linkedId == null
          ? '${hypothesis.explanation} Isso foi apenas uma observação, sem '
              'um registro específico para revisar.'
          : '${hypothesis.explanation} Não encontrei os detalhes desse '
              'registro para revisar.';
    } else {
      final type = eventTypeFromString(row['type'] as String);
      Map<String, dynamic> data = const {};
      try {
        data = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      } catch (_) {}
      final occurredAt =
          DateTime.tryParse(row['created_at'] as String) ?? hypothesis.estimatedPeak;
      if (type == null) {
        description = '${hypothesis.explanation} Não encontrei os detalhes '
            'desse registro para revisar.';
      } else {
        description =
            '${describeLoggedEvent(type, data, occurredAt)} Quer fazer '
            'alguma alteração?';
        options = const ['Está correto', 'Fazer alterações'];
      }
    }
    if (!mounted) return;
    setState(() {
      _messages.add(Message('assistant', description));
      if (options.isEmpty) {
        _pendingHypothesis = null;
        _reviewingResolvedHypothesis = false;
        _reviewedEventId = null;
        _guidedPrompt = null;
        _interactionMode = _InteractionMode.free;
      } else {
        _pendingHypothesis = hypothesis;
        _reviewingResolvedHypothesis = true;
        _reviewedEventId = linkedId;
        _awaitingHypothesisCorrection = false;
        _guidedPrompt = _GuidedPrompt(
          moduleId: 'timeline',
          kind: FieldKind.option,
          question: description,
          options: options,
        );
        _interactionMode = _InteractionMode.guided;
      }
    });
  }

  /// Maps an [OrchestratorReply.guidedModuleId] back to the
  /// [HypothesisType] it resolves — used only to record what a "Corrigir"
  /// answer turned out to actually be, never to drive classification.
  HypothesisType? _hypothesisTypeForModuleId(String? moduleId) {
    switch (moduleId) {
      case 'meal':
        return HypothesisType.meal;
      case 'insulin':
        return HypothesisType.insulin;
      case 'exercise':
        return HypothesisType.exercise;
      default:
        return null;
    }
  }

  /// Handles a tap on the timeline's Sim/Corrigir/Ignorar options (or, once
  /// "Corrigir" is chosen, the free-text answer that follows) — the only
  /// place [_pendingHypothesis] is ever resolved. See
  /// docs/fsm/past_event_interpreter.mmd for why this stays separate from
  /// the deterministic FSM's own guided modules.
  Future<void> _handleTimelineGuidedValue(String value) async {
    final hypothesis = _pendingHypothesis;
    if (hypothesis == null) {
      setState(() {
        _guidedPrompt = null;
        _interactionMode = _InteractionMode.free;
      });
      return;
    }

    if (_reviewingResolvedHypothesis) {
      _reviewingResolvedHypothesis = false;
      final oldEventId = _reviewedEventId;
      _reviewedEventId = null;
      if (value == 'Está correto') {
        _pendingHypothesis = null;
        setState(() {
          _messages.add(Message('user', value));
          _messages.add(Message('assistant', 'Certo, mantido como está.'));
          _guidedPrompt = null;
          _interactionMode = _InteractionMode.free;
        });
        return;
      }
      // "Fazer alterações": the old record is dropped and redone from
      // scratch through the same guided module a fresh confirmation uses
      // — never a bespoke pre-filled editor (see
      // docs/fsm/past_event_interpreter.mmd).
      final eventType = eventTypeFromString(hypothesis.type.name);
      if (eventType == null) {
        _pendingHypothesis = null;
        setState(() {
          _messages.add(Message('user', value));
          _guidedPrompt = null;
          _interactionMode = _InteractionMode.free;
        });
        return;
      }
      if (oldEventId != null) {
        await LocalDatabase.instance.deleteEventById(oldEventId);
      }
      _hypothesisAwaitingEventLink = hypothesis;
      _pendingHypothesis = null;
      setState(() {
        _messages.add(Message('user', value));
        _isLoading = true;
      });
      final reply = await _orchestrator.confirmHypothesisEvent(
        eventType,
        occurredAt: hypothesis.estimatedStart,
      );
      if (!mounted) return;
      _presentReply(reply);
      return;
    }

    if (_awaitingHypothesisCorrection) {
      _awaitingHypothesisCorrection = false;
      setState(() {
        _messages.add(Message('user', value));
        _isLoading = true;
      });
      final reply = await _getOrchestratorReply(
        value,
        seedEventCreatedAt: hypothesis.estimatedStart,
      );
      if (!mounted) return;
      await LocalDatabase.instance.updateHypothesisStatus(
        hypothesis.id,
        status: HypothesisStatus.corrected,
        type: _hypothesisTypeForModuleId(reply.guidedModuleId),
      );
      _hypothesisAwaitingEventLink = hypothesis;
      _pendingHypothesis = null;
      _presentReply(reply);
      return;
    }

    switch (value) {
      case '✔️ Sim':
        await LocalDatabase.instance.updateHypothesisStatus(
          hypothesis.id,
          status: HypothesisStatus.confirmed,
        );
        final eventType = eventTypeFromString(hypothesis.type.name);
        if (eventType == null) {
          _pendingHypothesis = null;
          setState(() {
            _messages.add(Message('user', value));
            _messages.add(
              Message('assistant', 'Certo, obrigado por confirmar!'),
            );
            _guidedPrompt = null;
            _interactionMode = _InteractionMode.free;
          });
          return;
        }
        _hypothesisAwaitingEventLink = hypothesis;
        _pendingHypothesis = null;
        setState(() {
          _messages.add(Message('user', value));
          _isLoading = true;
        });
        final reply = await _orchestrator.confirmHypothesisEvent(
          eventType,
          occurredAt: hypothesis.estimatedStart,
        );
        if (!mounted) return;
        _presentReply(reply);
        return;
      case '✏️ Corrigir':
        _awaitingHypothesisCorrection = true;
        setState(() {
          _messages.add(Message('user', value));
          _messages.add(Message('assistant', 'O que aconteceu, então?'));
          _guidedPrompt = _GuidedPrompt(
            moduleId: 'timeline',
            kind: FieldKind.freeText,
            question: 'O que aconteceu, então?',
          );
          _interactionMode = _InteractionMode.guided;
        });
        return;
      case '❌ Ignorar':
      default:
        await LocalDatabase.instance.updateHypothesisStatus(
          hypothesis.id,
          status: HypothesisStatus.dismissed,
        );
        _pendingHypothesis = null;
        setState(() {
          _messages.add(Message('user', value));
          _messages.add(Message('assistant', 'Tudo bem, sem problemas.'));
          _guidedPrompt = null;
          _interactionMode = _InteractionMode.free;
        });
    }
  }

  /// Routes [prompt] through the on-device event parser + the FSM
  /// (`ConversationOrchestrator`). Gemma never generates the text shown to
  /// the user directly — see nlu.dart / orchestrator.dart.
  Future<OrchestratorReply> _getOrchestratorReply(
    String prompt, {
    Uint8List? audioBytes,
    DateTime? seedEventCreatedAt,
  }) async {
    return _orchestrator.respond(prompt, _semanticInterpreter,
        audioBytes: audioBytes,
        recentContext: _recentContextLines(),
        seedEventCreatedAt: seedEventCreatedAt);
  }

  /// Last few chat turns (oldest first, excluding the prompt just sent),
  /// only used to shape Nuno's free_reply tone — see docs/fsm/nuno.mmd.
  List<String> _recentContextLines() {
    if (_messages.length <= 1) return const [];
    final history = _messages.sublist(0, _messages.length - 1);
    const maxTurns = FsmContract.nunoContextWindowTurns;
    final recent = history.length > maxTurns
        ? history.sublist(history.length - maxTurns)
        : history;
    return recent.map((message) {
      final speaker = message.role == 'user' ? 'Usuário' : 'Nuno';
      final text = message.text.length > 200
          ? '${message.text.substring(0, 200)}...'
          : message.text;
      return '$speaker: $text';
    }).toList();
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
                  'É preciso conceder "Acesso a todos os arquivos" ao DiabAI '
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

  // Relocated (from a former popup menu on Nuno's own app bar) into
  // Glicemia's app bar menu -- this is the only way to load the on-device
  // model, since it's never auto-loaded at startup (see _defaultModelPath).
  Future<void> _promptInitModel() async {
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_llmRuntime != null
              ? 'Modelo local inicializado.'
              : 'Falha ao inicializar modelo.'),
        ));
      }
    }
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

  Future<void> _signOut() async {
    await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _llmRuntime?.dispose();
    _semanticDiagnostics.dispose();
    _rag.dispose();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // Scrolls to the newest message once its frame is laid out; checked on
  // every build so it fires regardless of which code path appended it.
  void _scrollToBottomIfNewMessage() {
    if (_messages.length == _lastScrolledMessageCount) return;
    _lastScrolledMessageCount = _messages.length;
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// Plays back (or stops) the WAV recorded for a voice message, so the
  /// user can confirm it captured what they intended to say.
  Future<void> _toggleAudioPlayback(String path) async {
    if (_playingAudioPath == path) {
      await _audioPlayer.stop();
      if (mounted) setState(() => _playingAudioPath = null);
      return;
    }
    await _audioPlayer.stop();
    setState(() => _playingAudioPath = path);
    await _audioPlayer.play(DeviceFileSource(path));
  }

  /// Starts or stops microphone recording when the mic button is tapped.
  /// On stop, the recorded audio is sent straight to the on-device model
  /// as an audio turn (see `_sendMessage`) instead of first transcribing
  /// it to text \u2014 Gemma 4 is multimodal and understands speech directly.
  /// Recording auto-stops at 30s, Gemma 4's native audio input limit.
  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final path = await _audioRecorder.stop();
      _recordingTimer?.cancel();
      setState(() {
        _isRecording = false;
        _recordingElapsed = Duration.zero;
      });
      if (path != null && mounted) {
        Uint8List? audioBytes;
        try {
          audioBytes = await File(path).readAsBytes();
        } catch (_) {
          // Ignore; handled below via null result.
        }
        if (!mounted) return;
        if (audioBytes == null || audioBytes.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Não consegui capturar o áudio. Tente novamente ou digite '
                'sua mensagem.',
              ),
            ),
          );
          return;
        }
        await _sendMessage('🎤 Mensagem de voz', false, audioBytes, path);
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
        '${dir.path}/diabai_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
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
      if (_recordingElapsed >= const Duration(seconds: 30)) {
        _toggleRecording();
      }
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _formatMessageTime(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// Replaces the text field while recording, showing a pulsing mic icon
  /// and elapsed time instead of a keyboard. Embedded inside the pill
  /// input container, so it carries no border/background of its own.
  Widget _buildRecordingIndicator() {
    return Row(
      children: [
        GestureDetector(
          onTap: _toggleRecording,
          child: const Icon(Icons.stop_circle,
              color: DiabAIPalette.offline, size: 22),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Gravando...',
              style: TextStyle(color: DiabAIPalette.textSecondary)),
        ),
        Text(_formatDuration(_recordingElapsed),
            style: const TextStyle(color: DiabAIPalette.textMuted)),
      ],
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
    final modelReady = _llmRuntime != null;
    final isOnboarding = _guidedPrompt?.moduleId == 'onboarding';
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToBottomIfNewMessage());
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                image: DecorationImage(
                  image: AssetImage('assets/images/diabai_icon_small.png'),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Nuno is the assistant persona shown to users; DiabAI is
                  // the product/app name — shown instead while the guided
                  // onboarding flow is still asking questions.
                  Text(
                    isOnboarding ? 'Bem Vindo(a) ao DiabAI' : 'Nuno',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: DiabAIPalette.textPrimary,
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: modelReady
                              ? DiabAIPalette.online
                              : DiabAIPalette.offline,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _modelLoading
                            ? 'Carregando modelo...'
                            : modelReady
                                ? 'Modelo local pronto'
                                : 'Modelo não carregado',
                        style: const TextStyle(
                          fontSize: 12,
                          color: DiabAIPalette.accent,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (widget.embedded)
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              tooltip: 'Recolher conversa',
              onPressed: widget.onCollapse,
            ),
        ],
      ),
      body: _isBootstrapping || _bootstrapError != null
          ? _buildBootstrapBody()
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isUser = message.role == 'user';
                      final isFirstOfRun = index == 0 ||
                          _messages[index - 1].role != message.role;
                      final textColor =
                          isUser ? Colors.white : DiabAIPalette.textSecondary;
                      final audioPath = message.audioPath;
                      final isPlaying =
                          audioPath != null && _playingAudioPath == audioPath;
                      final bubbleContent = audioPath == null
                          ? Text(message.text, style: TextStyle(color: textColor))
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    isPlaying
                                        ? Icons.stop_circle
                                        : Icons.play_circle_fill,
                                    color: textColor,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  tooltip: isPlaying
                                      ? 'Parar'
                                      : 'Ouvir mensagem de voz',
                                  onPressed: () =>
                                      _toggleAudioPlayback(audioPath),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(message.text,
                                      style: TextStyle(color: textColor)),
                                ),
                              ],
                            );

                      return Padding(
                        padding:
                            EdgeInsets.only(top: isFirstOfRun ? 10 : 2, bottom: 2),
                        child: Row(
                          mainAxisAlignment: isUser
                              ? MainAxisAlignment.end
                              : MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (!isUser)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: isFirstOfRun
                                    ? Container(
                                        width: 28,
                                        height: 28,
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          image: DecorationImage(
                                            image: AssetImage(
                                                'assets/images/diabai_icon_small.png'),
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                      )
                                    : const SizedBox(width: 28),
                              ),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.76,
                              ),
                              child: Column(
                                crossAxisAlignment: isUser
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      gradient: isUser
                                          ? DiabAIPalette.userBubbleGradient
                                          : null,
                                      color:
                                          isUser ? null : DiabAIPalette.surface,
                                      border: isUser
                                          ? null
                                          : Border.all(
                                              color:
                                                  DiabAIPalette.surfaceBorder),
                                      borderRadius: BorderRadius.only(
                                        topLeft: const Radius.circular(18),
                                        topRight: const Radius.circular(18),
                                        bottomLeft:
                                            Radius.circular(isUser ? 18 : 4),
                                        bottomRight:
                                            Radius.circular(isUser ? 4 : 18),
                                      ),
                                    ),
                                    child: bubbleContent,
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _formatMessageTime(
                                              message.timestamp),
                                          style: const TextStyle(
                                            color: DiabAIPalette.textMuted,
                                            fontSize: 11,
                                          ),
                                        ),
                                        if (isUser) ...[
                                          const SizedBox(width: 4),
                                          const Text('✓✓',
                                              style: TextStyle(
                                                color: DiabAIPalette.accent,
                                                fontSize: 11,
                                              )),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
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
                          active: widget.isExpanded,
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
    final hasText = _controller.text.trim().isNotEmpty;
    final canSend = !(_isLoading || _isRecording) && hasText;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: DiabAIPalette.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: DiabAIPalette.surfaceBorder),
                ),
                child: _isRecording
                    ? _buildRecordingIndicator()
                    : Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              decoration: const InputDecoration(
                                hintText:
                                    'Escreva aqui ou clique no microfone para falar',
                                hintStyle:
                                    TextStyle(color: DiabAIPalette.iconMuted),
                                border: InputBorder.none,
                                isCollapsed: true,
                              ),
                              style: const TextStyle(
                                  color: DiabAIPalette.textPrimary),
                              minLines: 1,
                              maxLines: 4,
                              textInputAction: TextInputAction.send,
                              onChanged: (_) => setState(() {}),
                              onSubmitted: (_) => _sendMessage(),
                            ),
                          ),
                          IconButton(
                            onPressed: _isLoading ? null : _toggleRecording,
                            icon: const Icon(Icons.mic),
                            color: DiabAIPalette.iconMuted,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            tooltip: 'Gravar mensagem de voz',
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: canSend ? _sendMessage : null,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: canSend ? DiabAIPalette.accentGradient : null,
                  color: canSend ? null : DiabAIPalette.surface,
                ),
                child: Icon(
                  Icons.send,
                  size: 18,
                  color: canSend ? Colors.white : DiabAIPalette.iconMuted,
                ),
              ),
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
    required this.active,
    required this.onSubmit,
    required this.onExit,
  });

  final _GuidedPrompt prompt;
  final bool isLoading;

  /// True only while this panel is actually on-screen (see
  /// [ChatPage.isExpanded]) — the panel is otherwise permanently mounted,
  /// just slid off-screen, so [_GuidedInputPanelState] must not grab
  /// keyboard focus while this is false.
  final bool active;
  final ValueChanged<String> onSubmit;
  final VoidCallback onExit;

  @override
  State<_GuidedInputPanel> createState() => _GuidedInputPanelState();
}

class _GuidedInputPanelState extends State<_GuidedInputPanel> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String? _selectedUnit;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _initSelectedUnit();
    _requestFocusForCurrentQuestion();
  }

  @override
  void didUpdateWidget(_GuidedInputPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prompt.question != widget.prompt.question) {
      _initSelectedUnit();
      _obscurePassword = true;
      _requestFocusForCurrentQuestion();
    } else if (!oldWidget.active && widget.active) {
      // The panel became visible without a new question (e.g. the user
      // just expanded the chat) — focus now instead of never, since the
      // mount-time request below was skipped while inactive.
      _requestFocusForCurrentQuestion();
    }
  }

  /// Opens the keyboard automatically for a free-text/numeric question
  /// instead of requiring a tap first — e.g. the weight question. A no-op
  /// for yesNo/option/time questions, which have no text field to focus,
  /// and while [_GuidedInputPanel.active] is false, since this panel stays
  /// mounted (just slid off-screen) even when collapsed — see
  /// [ChatPage.isExpanded].
  void _requestFocusForCurrentQuestion() {
    if (!widget.active) return;
    final prompt = widget.prompt;
    final hasTextField = prompt.kind != FieldKind.yesNo &&
        prompt.kind != FieldKind.option &&
        prompt.kind != FieldKind.time;
    if (!hasTextField) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _initSelectedUnit() {
    _selectedUnit =
        widget.prompt.unitOptions.isNotEmpty ? widget.prompt.unitOptions.first : null;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.isLoading) return;
    final value = _selectedUnit == null ? text : '$text $_selectedUnit';
    widget.onSubmit(value);
  }

  /// Opens a time picker for a `FieldKind.time` question and submits the
  /// chosen moment as an ISO-8601 string. Prefers the drag-on-the-curve
  /// picker (touch-and-hold the marker and slide it over the recent
  /// glucose curve) whenever there's enough local history to draw one;
  /// otherwise falls back to the plain time-of-day wheel, rolled back to
  /// yesterday if that time-of-day hasn't happened yet today so "escolher
  /// horário" can express something earlier today without a date picker.
  /// The curve window and initial marker are centered on
  /// [_GuidedPrompt.eventCreatedAt] (e.g. a confirmed hypothesis's own
  /// estimated moment) when known, instead of always the latest reading.
  Future<void> _pickTime() async {
    final centerOn = widget.prompt.eventCreatedAt;
    final curvePoints =
        await loadRecentGlucosePoints(centerOn: centerOn);
    if (!mounted) return;
    if (curvePoints.length >= 2) {
      final chosen = await showGlucoseCurveTimePicker(
        context,
        points: curvePoints,
        initialTime: centerOn,
        icon: GuidedModuleCatalog.byId(widget.prompt.moduleId).icon,
      );
      if (chosen != null && mounted) widget.onSubmit(chosen.toIso8601String());
      return;
    }
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked == null || !mounted) return;
    final now = DateTime.now();
    var chosen = DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
    if (chosen.isAfter(now)) {
      chosen = chosen.subtract(const Duration(days: 1));
    }
    widget.onSubmit(chosen.toIso8601String());
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    // `options` always contains at least "Outras opções" (see
    // `_withOtherOptions` in orchestrator.dart), so its mere presence can't
    // decide the control: only yesNo/option fields carry real choices.
    final usesOptions = (prompt.kind == FieldKind.yesNo ||
            prompt.kind == FieldKind.option) &&
        prompt.options.isNotEmpty;
    final numeric = prompt.kind == FieldKind.number;
    final isTime = prompt.kind == FieldKind.time;
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
                  prompt.shortTitle ?? UiText.current.get(module.titleKey),
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
          if (isTime)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: widget.isLoading
                        ? null
                        : () => widget.onSubmit('Agora'),
                    child: const Text('Agora'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: widget.isLoading ? null : _pickTime,
                    icon: const Icon(Icons.access_time),
                    label: const Text('Escolher horário'),
                  ),
                ),
              ],
            )
          else if (usesOptions)
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
          else ...[
            if (numeric && prompt.unitOptions.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final unit in prompt.unitOptions)
                      ChoiceChip(
                        label: Text(unit),
                        selected: _selectedUnit == unit,
                        onSelected: widget.isLoading
                            ? null
                            : (_) => setState(() => _selectedUnit = unit),
                      ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    obscureText: prompt.obscureInput && _obscurePassword,
                    keyboardType: numeric
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : TextInputType.text,
                    decoration: InputDecoration(
                        hintText: prompt.numericInputHint ??
                          UiText.current.get('guided.inputHint'),
                      border: const OutlineInputBorder(),
                      suffixIcon: prompt.obscureInput
                          ? IconButton(
                              icon: Icon(_obscurePassword
                                  ? Icons.visibility
                                  : Icons.visibility_off),
                              tooltip: _obscurePassword
                                  ? 'Mostrar senha'
                                  : 'Ocultar senha',
                              onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword),
                            )
                          : null,
                    ),
                    minLines: 1,
                    maxLines: numeric || prompt.obscureInput ? 1 : 3,
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
            if (prompt.options.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final option in prompt.options)
                    TextButton(
                      onPressed: widget.isLoading
                          ? null
                          : () => widget.onSubmit(option),
                      child: Text(option),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
