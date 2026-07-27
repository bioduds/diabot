# Diabot

Diabot é um MVP Flutter para testar conversas simples com Gemma 3 1B via Ollama HTTP.

## Como usar

1. Instale Flutter e configure o Android SDK.
2. Garanta que o Ollama esteja rodando localmente em `http://127.0.0.1:11434`.
3. No diretório `diabot`, execute:

```bash
flutter pub get
flutter run
```

## MVP

- Uma tela única
- Campo de texto
- Botão enviar
- Histórico simples de mensagens
- Botão limpar conversa
- Indicador visual de processamento

## Requisitos

- Android device ou emulador
- Ollama rodando localmente
- Modelo `gemma3:1b` disponível no Ollama
