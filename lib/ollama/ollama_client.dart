import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A model that is already pulled onto this machine.
class OllamaModel {
  OllamaModel({
    required this.name,
    required this.capabilities,
    this.parameterSize,
    this.contextLength,
  });

  final String name;
  final List<String> capabilities;
  final String? parameterSize;
  final int? contextLength;

  /// Whether this model can hold a conversation.
  bool get canChat => capabilities.contains('completion');

  /// Whether this model can produce embeddings.
  ///
  /// This deliberately reads `capabilities` rather than `details.embedding_length`.
  /// Chat models also report an `embedding_length` (it is their internal hidden
  /// size, e.g. 2880 for gpt-oss), so filtering on that field would happily
  /// offer you a chat model as an embedder and then fail at request time.
  bool get canEmbed => capabilities.contains('embedding');

  /// Reasoning models emit a separate `thinking` field before the answer.
  bool get thinks => capabilities.contains('thinking');

  factory OllamaModel.fromJson(Map<String, dynamic> json) {
    final details = (json['details'] as Map<String, dynamic>?) ?? const {};
    return OllamaModel(
      name: json['name'] as String,
      capabilities:
          (json['capabilities'] as List?)?.cast<String>() ?? const <String>[],
      parameterSize: details['parameter_size'] as String?,
      contextLength: details['context_length'] as int?,
    );
  }

  @override
  String toString() => name;
}

class ChatMessage {
  const ChatMessage(this.role, this.content);
  final String role; // 'system' | 'user' | 'assistant'
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// One streamed fragment from /api/chat.
class ChatChunk {
  const ChatChunk({this.content, this.thinking, this.done = false});
  final String? content;
  final String? thinking;
  final bool done;
}

class OllamaException implements Exception {
  OllamaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thin Dart client over the Ollama HTTP API.
///
/// Everything the app needs is plain REST on localhost, which is why this
/// project needs no Python sidecar: no LangChain, no Chroma server, no
/// sentence-transformers, no packaging a Python runtime into the .app bundle.
class OllamaClient {
  OllamaClient({Uri? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? Uri.parse('http://127.0.0.1:11434'),
        _client = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _client;

  /// mxbai-embed-large is an asymmetric model: queries are meant to carry a
  /// task prefix, passages are not.
  ///
  /// Measured on sample_kb it makes no difference at all — hit@1 83% / hit@3
  /// 92% with it and without it (tool/retrieval_quality/experiment.dart, section C). It is kept
  /// because it is free and may matter at larger scale, but it is not doing
  /// work here. A/B your retrieval tricks rather than trusting the README.
  static const String mxbaiQueryPrefix =
      'Represent this sentence for searching relevant passages: ';

  /// Cheap liveness probe: the installed Ollama version, or null if it is not
  /// reachable. Never throws — "is it up?" is a question with a `no` answer,
  /// not an exceptional condition, and the caller polls this in a loop.
  Future<String?> version({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final res =
          await _client.get(baseUrl.resolve('/api/version')).timeout(timeout);
      if (res.statusCode != 200) return null;
      return (jsonDecode(res.body) as Map<String, dynamic>)['version']
          as String?;
    } on Object {
      return null;
    }
  }

  Future<List<OllamaModel>> listModels() async {
    final http.Response res;
    try {
      res = await _client
          .get(baseUrl.resolve('/api/tags'))
          .timeout(const Duration(seconds: 10));
    } on Object catch (e) {
      throw OllamaException(
        'Could not reach Ollama at $baseUrl.\n'
        'Is it running? Try: ollama serve\n\n$e',
      );
    }
    if (res.statusCode != 200) {
      throw OllamaException('GET /api/tags failed (${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final models = (body['models'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(OllamaModel.fromJson)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return models;
  }

  /// Embeds [input] in batches. Returns one vector per input, in order.
  Future<List<List<double>>> embed({
    required String model,
    required List<String> input,
    int batchSize = 16,
    void Function(int done, int total)? onProgress,
  }) async {
    final out = <List<double>>[];
    for (var i = 0; i < input.length; i += batchSize) {
      final batch = input.sublist(
        i,
        (i + batchSize).clamp(0, input.length),
      );
      final http.Response res;
      try {
        res = await _client
            .post(
              baseUrl.resolve('/api/embed'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'model': model, 'input': batch}),
            )
            .timeout(const Duration(minutes: 5));
      } on Object catch (e) {
        throw OllamaException('Embedding request failed: $e');
      }
      if (res.statusCode != 200) {
        throw OllamaException(
          'POST /api/embed failed (${res.statusCode}): ${res.body}',
        );
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final vectors = (body['embeddings'] as List?)?.cast<List>();
      if (vectors == null || vectors.length != batch.length) {
        throw OllamaException(
          'Expected ${batch.length} embeddings, got ${vectors?.length}',
        );
      }
      for (final v in vectors) {
        out.add(v.map((e) => (e as num).toDouble()).toList());
      }
      onProgress?.call(out.length, input.length);
    }
    return out;
  }

  Future<List<double>> embedOne({
    required String model,
    required String input,
  }) async {
    final r = await embed(model: model, input: [input]);
    return r.first;
  }

  /// Streams a chat completion. Ollama returns newline-delimited JSON when
  /// `stream: true` — one JSON object per line, not SSE, so there is no
  /// `data:` prefix to strip.
  ///
  /// Cancelling the subscription on this stream closes the underlying
  /// connection, which is how the UI's stop button aborts generation.
  /// Streams a chat completion.
  ///
  /// Set [think] to false on a reasoning model when you want the answer and not
  /// the scratchpad — a one-line rewrite does not need several seconds of
  /// visible deliberation first. Ignored by models without the capability.
  Stream<ChatChunk> chat({
    required String model,
    required List<ChatMessage> messages,
    double temperature = 0.2,
    bool? think,
  }) async* {
    final req = http.Request('POST', baseUrl.resolve('/api/chat'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'messages': messages.map((m) => m.toJson()).toList(),
        'stream': true,
        'options': {'temperature': temperature},
        'think': ?think,
      });

    final http.StreamedResponse res;
    try {
      res = await _client.send(req);
    } on Object catch (e) {
      throw OllamaException('Could not reach Ollama at $baseUrl: $e');
    }

    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw OllamaException('POST /api/chat failed (${res.statusCode}): $body');
    }

    final lines =
        res.stream.transform(utf8.decoder).transform(const LineSplitter());

    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final Map<String, dynamic> obj;
      try {
        obj = jsonDecode(line) as Map<String, dynamic>;
      } on FormatException {
        continue; // ignore keep-alive / partial noise
      }
      if (obj['error'] != null) {
        throw OllamaException('Ollama error: ${obj['error']}');
      }
      final msg = obj['message'] as Map<String, dynamic>?;
      final content = msg?['content'] as String?;
      // Reasoning models (gpt-oss) stream their scratchpad here first.
      final thinking = msg?['thinking'] as String?;
      final done = obj['done'] == true;

      if ((content != null && content.isNotEmpty) ||
          (thinking != null && thinking.isNotEmpty) ||
          done) {
        yield ChatChunk(content: content, thinking: thinking, done: done);
      }
      if (done) return;
    }
  }

  void close() => _client.close();
}
