import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logging/app_log.dart';
import 'explanation_prompt.dart';
import 'llm_config.dart';
import 'move_explainer.dart';

/// [MoveExplainer] for any OpenAI-compatible chat-completions API.
class OpenAiCompatExplainer implements MoveExplainer {
  OpenAiCompatExplainer({
    required this.credential,
    this.timeout = const Duration(seconds: 20),
    http.Client? client,
  }) : _client = client ?? http.Client();

  final LlmCredential credential;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<MoveExplanation> explainMove(ExplanationContext context) async {
    final prompt = buildPrompt(context);
    // Verbatim, never the key.
    AppLog.instance.info(
      'llm',
      'asking ${credential.model} (${credential.provider.label}) about '
          '${context.playedSan} — ${context.classification.label}\n'
          '--- system ---\n$explanationSystemPrompt\n'
          '--- user ---\n$prompt',
    );

    final clock = Stopwatch()..start();
    final http.Response response;
    try {
      response = await _postWithOneRetry(chatPayload(credential, prompt));
    } catch (e) {
      AppLog.instance.error(
        'llm',
        'no answer after ${formatDuration(clock.elapsed)}: $e',
      );
      rethrow;
    }

    // Every failure below throws an Exception, never a cast Error.
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw _unreadable('Unexpected LLM response: ${response.body}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw _unreadable('Unexpected LLM response: ${response.body}');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw _unreadable('LLM returned no choices: ${response.body}');
    }
    final first = choices.first;
    final message = first is Map ? first['message'] : null;
    final content = message is Map ? message['content'] : null;
    // Thinking kept out of `content`: NVIDIA's `reasoning_content`, Groq's
    // `reasoning`. Only read to explain an empty answer.
    final reasoning = message is Map
        ? message['reasoning_content'] ?? message['reasoning']
        : null;
    final raw = content is String ? content : '';
    // Raw, before stripping, so an empty answer can be seen for what it was.
    AppLog.instance.info(
      'llm',
      'answered in ${formatDuration(clock.elapsed)}\n$raw',
    );
    final answer = stripReasoning(raw);
    if (answer.isEmpty) {
      final thought =
          raw.trim().isNotEmpty ||
          (reasoning is String && reasoning.trim().isNotEmpty);
      throw _unreadable(
        thought
            ? 'LLM thought but never answered: ${credential.model} returned '
                  'reasoning only. Try a model that does not think.'
            : 'LLM returned an empty message.',
      );
    }

    return explanationFrom(
      answer,
      model:
          credential.provider.presetFor(credential.model)?.label ??
          credential.model,
    );
  }

  /// Logs [message] and returns the exception to throw.
  http.ClientException _unreadable(String message) {
    AppLog.instance.error('llm', message);
    return http.ClientException(message);
  }

  Future<http.Response> _postWithOneRetry(Map<String, Object?> payload) async {
    var response = await _post(payload);
    if (response.statusCode == 429 || response.statusCode >= 500) {
      AppLog.instance.warn(
        'llm',
        'retrying after ${response.statusCode}: ${response.body}',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      response = await _post(payload);
    }
    if (response.statusCode != 200) {
      throw http.ClientException(
        'LLM request failed (${response.statusCode}): ${response.body}',
      );
    }
    return response;
  }

  @override
  Future<void> dispose() async => _client.close();

  Future<http.Response> _post(Map<String, Object?> payload) {
    return _client
        .post(
          Uri.parse('${credential.provider.baseUrl}/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${credential.apiKey}',
          },
          body: jsonEncode(payload),
        )
        .timeout(timeout);
  }
}
