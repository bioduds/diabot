import 'dart:convert';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import 'login_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
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

/// Shows [LoginPage] when signed out, [ChatPage] when signed in.
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
        return snapshot.data != null ? const ChatPage() : const LoginPage();
      },
    );
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

  Future<String> _queryOllama(String prompt) async {
    // If an on-device LlamaParent is initialized, use it.
    if (_llamaParent != null && _llamaParent!.status == LlamaStatus.ready) {
      final chatHistory = ChatHistory();
      chatHistory.addMessage(
          role: Role.system,
          content:
              'Você é uma IA especializada em educação sobre diabetes. Seu objetivo é ensinar, explicar conceitos e auxiliar o usuário a compreender melhor sua condição. Você nunca substitui profissionais de saúde. Você deverá: ensinar; explicar; acolher; reconhecer incertezas; adaptar a profundidade das respostas ao contexto apresentado. Você NÃO deverá: prescrever tratamentos; substituir profissionais de saúde; apresentar certezas inexistentes; realizar recomendações perigosas ou categóricas. Seu principal objetivo é aumentar a autonomia do usuário ao longo do tempo.');
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
          'content': 'Você é uma IA especializada em educação sobre diabetes. Seu objetivo é ensinar, explicar conceitos e auxiliar o usuário a compreender melhor sua condição. Você nunca substitui profissionais de saúde. Você deverá: ensinar; explicar; acolher; reconhecer incertezas; adaptar a profundidade das respostas ao contexto apresentado. Você NÃO deverá: prescrever tratamentos; substituir profissionais de saúde; apresentar certezas inexistentes; realizar recomendações perigosas ou categóricas. Seu principal objetivo é aumentar a autonomia do usuário ao longo do tempo.'
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
    super.dispose();
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
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Digite sua pergunta sobre diabetes...',
                      border: OutlineInputBorder(),
                    ),
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isLoading ? null : _sendMessage,
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
