import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'stt.dart';
import 'user_profile.dart';

/// Profile editor reusing the chat-bubble UI style. First-login onboarding
/// runs only through the FSM initialization module in `initialization.dart`.
///
/// When [existingProfile] is provided, the flow starts pre-filled with the
/// current answers so it can be reused as an "Editar perfil" screen.
class ProfileEditorPage extends StatefulWidget {
  final UserProfile? existingProfile;

  /// Called with the saved profile once all questions are answered.
  final void Function(UserProfile) onDone;

  const ProfileEditorPage({
    super.key,
    this.existingProfile,
    required this.onDone,
  });

  @override
  State<ProfileEditorPage> createState() => _OnboardingPageState();
}

class _OnboardingBubble {
  final bool isBot;
  final String text;

  _OnboardingBubble(this.isBot, this.text);
}

class _OnboardingPageState extends State<ProfileEditorPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_OnboardingBubble> _bubbles = [];
  late UserProfile _profile;
  int _step = 0;

  // Voice input: answers can be recorded as a WAV file and transcribed
  // on-device with Whisper Tiny (via SttService), same as the chat page.
  final AudioRecorder _audioRecorder = AudioRecorder();
  final SttService _stt = SttService();
  bool _isRecording = false;
  bool _isTranscribing = false;
  Duration _recordingElapsed = Duration.zero;
  Timer? _recordingTimer;

  @override
  void initState() {
    super.initState();
    _profile = widget.existingProfile ?? UserProfile();
    _prefillKnownFieldsAndStart();
    _stt.ensureInitialized(language: _profile.idioma).catchError((_) {});
  }

  /// Auto-fills fields the app can already infer so it never asks again
  /// for something it already knows:
  /// - `idioma`: from the device's system locale, so the on-device speech
  ///   recognizer can be told which language to force instead of
  ///   auto-detecting it per recording (which was producing inconsistent
  ///   Portuguese/English/Russian transcriptions of the same phrase).
  /// - `nome`: from the Google account display name, on first login only.
  ///
  /// The "idioma" and "nome" questions (in that fixed leading order in
  /// [onboardingQuestions]) are skipped whenever already known. If the
  /// device locale can't be read for some reason, `idioma` stays empty and
  /// the question is asked normally as a fallback.
  void _prefillKnownFieldsAndStart() {
    final isFirstLogin = widget.existingProfile == null;

    if (_profile.idioma.isEmpty) {
      final localeCode =
          WidgetsBinding.instance.platformDispatcher.locale.languageCode;
      if (localeCode.isNotEmpty) {
        _profile.idioma = localeCode;
      }
    }

    if (isFirstLogin) {
      final displayName =
          FirebaseAuth.instance.currentUser?.displayName?.trim();
      if (displayName != null && displayName.isNotEmpty) {
        _profile.nome = displayName;
      }
    }

    _step = 0;
    while (_step < 2 && onboardingQuestions[_step].getter(_profile).isNotEmpty) {
      _step += 1;
    }

    if (isFirstLogin && _profile.nome.isNotEmpty) {
      _bubbles.add(_OnboardingBubble(true,
          'Olá, ${_profile.nome}! Eu sou o Nuno, seu assistente inteligente. '
          'Vamos completar mais alguns '
          'dados rapidinho.'));
    }
    _askCurrentQuestion();
  }

  void _askCurrentQuestion() {
    final question = onboardingQuestions[_step];
    _bubbles.add(_OnboardingBubble(true, question.question));
    final existingAnswer = question.getter(_profile);
    _controller.text = existingAnswer;
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _submitAnswer() async {
    final answer = _controller.text.trim();
    if (answer.isEmpty) return;

    final question = onboardingQuestions[_step];
    question.setter(_profile, answer);

    setState(() {
      _bubbles.add(_OnboardingBubble(false, answer));
      _controller.clear();
      _step += 1;
    });

    if (_step >= onboardingQuestions.length) {
      await _profile.save();
      if (mounted) widget.onDone(_profile);
      return;
    }

    setState(_askCurrentQuestion);
  }

  @override
  void dispose() {
    _stt.dispose();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Starts or stops microphone recording when the mic button is tapped.
  /// On stop, the recorded audio is transcribed on-device with Whisper
  /// Tiny and the result is placed in the text field for review before
  /// sending.
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
                'N\u00e3o consegui entender o \u00e1udio. Tente novamente ou '
                'digite sua resposta.',
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
            content: Text('Permiss\u00e3o de microf\u00f4ne negada.'),
          ),
        );
      }
      return;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/diabai_onboarding_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
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
    final isEditing = widget.existingProfile != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Editar perfil' : 'Bem-vindo(a) ao DiabAI'),
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _bubbles.length,
              itemBuilder: (context, index) {
                final bubble = _bubbles[index];
                final isBot = bubble.isBot;
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  alignment:
                      isBot ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.75),
                    decoration: BoxDecoration(
                      color: isBot
                          ? Theme.of(context).colorScheme.surfaceContainerHighest
                          : Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      bubble.text,
                      style: TextStyle(
                        color: isBot
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                );
              },
            ),
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
                                  hintText: 'Digite sua resposta...',
                                  border: OutlineInputBorder(),
                                ),
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _submitAnswer(),
                              ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _isTranscribing ? null : _toggleRecording,
                    style: _isRecording
                        ? IconButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.errorContainer,
                          )
                        : null,
                    icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                    tooltip: _isRecording
                        ? 'Parar grava\u00e7\u00e3o'
                        : 'Gravar resposta por voz',
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: (_isRecording || _isTranscribing)
                        ? null
                        : _submitAnswer,
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
