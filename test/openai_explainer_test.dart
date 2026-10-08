import 'dart:convert';

import 'package:chess_mortem/llm/llm_config.dart';
import 'package:chess_mortem/llm/move_explainer.dart';
import 'package:chess_mortem/llm/openai_explainer.dart';
import 'package:chess_mortem/logging/app_log.dart';
import 'package:chess_mortem/model/classification.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(AppLog.instance.clear);
  tearDown(AppLog.instance.clear);

  final credential = LlmCredential(
    name: 'test key',
    provider: LlmProvider.groq,
    apiKey: 'sk-super-secret',
    model: 'test-model',
  );

  final context = ExplanationContext(
    fenBefore:
        'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3',
    playedSan: 'Bc4',
    mover: Side.white,
    classification: Classification.good,
    evalBeforePawns: 0.3,
    evalAfterPawns: 0.2,
    bestMoveSan: 'Bb5',
    bestLineSan: const ['Bb5', 'a6', 'Ba4'],
    refutationLineSan: const ['Nf6', 'd3'],
  );

  OpenAiCompatExplainer explainerAnswering(
    String content, {
    LlmCredential? key,
    String? reasoning,
    String? groqReasoning,
    void Function(Map<String, Object?> body)? onRequest,
  }) {
    return OpenAiCompatExplainer(
      credential: key ?? credential,
      client: MockClient((request) async {
        onRequest?.call(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': content,
                  'reasoning_content': ?reasoning,
                  'reasoning': ?groqReasoning,
                },
              },
            ],
          }),
          200,
        );
      }),
    );
  }

  String log() => AppLog.instance.asText();

  test('logs the prompt it sent and the answer it got back', () async {
    final explainer = explainerAnswering('Solid development\nBishop eyes f7.');
    addTearDown(explainer.dispose);

    await explainer.explainMove(context);

    // The request: which model, which move, and the messages verbatim.
    expect(log(), contains('test-model'));
    expect(log(), contains('Groq'));
    expect(log(), contains('Bc4'));
    expect(log(), contains('--- system ---'));
    expect(log(), contains('--- user ---'));
    expect(log(), contains('Better was Bb5'));
    // The answer as the model sent it.
    expect(log(), contains('Bishop eyes f7.'));
    // Every entry is tagged so the log can be read for LLM traffic alone.
    expect(AppLog.instance.entries.where((e) => e.tag == 'llm'), hasLength(2));
  });

  test('never writes the API key to the log', () async {
    final explainer = explainerAnswering('Fine\nA quiet developing move.');
    addTearDown(explainer.dispose);

    await explainer.explainMove(context);

    expect(log(), isNot(contains('sk-super-secret')));
  });

  test('a failed request says why in the log and still throws', () async {
    final explainer = OpenAiCompatExplainer(
      credential: credential,
      client: MockClient((_) async => http.Response('no key', 401)),
    );
    addTearDown(explainer.dispose);

    await expectLater(
      explainer.explainMove(context),
      throwsA(isA<http.ClientException>()),
    );

    final failures = AppLog.instance.entries.where(
      (e) => e.level == LogLevel.error,
    );
    expect(failures, hasLength(1));
    expect(failures.single.tag, 'llm');
    expect(failures.single.message, contains('401'));
  });

  test('a reasoning model keeps its thinking out of the explanation', () async {
    final explainer = explainerAnswering(
      '<think>Rook to d3 attacks h3. Is that the point? Yes.</think>\n'
      'Rook swings to the third rank\n\nRd3 hits the h3 pawn.',
    );
    addTearDown(explainer.dispose);

    final explanation = await explainer.explainMove(context);

    // A model typed in by hand is named by its id.
    expect(explanation.model, 'test-model');
    // One part: the whole answer, minus the thinking.
    expect(
      explanation.detail,
      'Rook swings to the third rank\n\nRd3 hits the h3 pawn.',
    );
    // The log still carries what the model actually sent, thinking included.
    expect(log(), contains('Is that the point?'));
  });

  test('thinking that never reached an answer is a failure', () async {
    final explainer = explainerAnswering(
      "<think>Here's a thinking process: 1. Analyze the input",
      reasoning: 'more of the same',
    );
    addTearDown(explainer.dispose);

    await expectLater(
      explainer.explainMove(context),
      throwsA(isA<http.ClientException>()),
    );

    final failure = AppLog.instance.entries.last;
    expect(failure.level, LogLevel.error);
    // Names the model, because choosing another one is the fix.
    expect(failure.message, contains('test-model'));
    expect(failure.message, contains('reasoning only'));
    // What the model did send is still in the log.
    expect(log(), contains("Here's a thinking process"));
  });

  test('a page that is not JSON is logged and fails cleanly', () async {
    final explainer = OpenAiCompatExplainer(
      credential: credential,
      client: MockClient(
        (_) async => http.Response('<html>Sign in</html>', 200),
      ),
    );
    addTearDown(explainer.dispose);

    await expectLater(
      explainer.explainMove(context),
      throwsA(isA<http.ClientException>()),
    );
    expect(AppLog.instance.entries.last.level, LogLevel.error);
    expect(log(), contains('<html>Sign in</html>'));
  });

  /// The request body one explanation sends, for a key on [provider] using
  /// [model].
  Future<Map<String, Object?>> bodyFor(
    LlmProvider provider,
    String model,
  ) async {
    Map<String, Object?>? sent;
    final explainer = explainerAnswering(
      'Fine\nA quiet move.',
      key: credential.copyWith(provider: provider, model: model),
      onRequest: (body) => sent = body,
    );
    addTearDown(explainer.dispose);
    await explainer.explainMove(context);
    return sent!;
  }

  test('asks NVIDIA not to think, and asks nobody else', () async {
    final nvidia = await bodyFor(LlmProvider.nvidiaNim, 'test-model');
    final groq = await bodyFor(LlmProvider.groq, 'test-model');

    expect(nvidia['chat_template_kwargs'], {'enable_thinking': false});
    // An unknown field is a 400 on stricter providers.
    expect(groq.containsKey('chat_template_kwargs'), isFalse);
  });

  test('asks each Groq model not to think in its own words', () async {
    // Qwen is the only family on Groq with an off switch...
    final qwen = await bodyFor(LlmProvider.groq, 'qwen/qwen3.6-27b');
    expect(qwen['reasoning_effort'], 'none');

    // ...gpt-oss has none, so a gpt-oss with no preset is asked to think as
    // little as it can. "none" is a 400 here.
    final gptOss = await bodyFor(LlmProvider.groq, 'openai/gpt-oss-20b');
    expect(gptOss['reasoning_effort'], 'low');

    // Anything else gets nothing: an unknown field is a 400.
    final other = await bodyFor(LlmProvider.groq, 'moonshotai/kimi-k2');
    expect(other.containsKey('reasoning_effort'), isFalse);
  });

  test('a measured model gets its own thinking level and token cap', () async {
    final groq = await bodyFor(LlmProvider.groq, 'openai/gpt-oss-120b');
    expect(groq['reasoning_effort'], 'medium');
    // Medium thinking uses up to ~1100 tokens, so the cap leaves room.
    expect(groq['max_tokens'], 2000);

    final nvidia = await bodyFor(
      LlmProvider.nvidiaNim,
      'nvidia/nemotron-3-super-120b-a12b',
    );
    expect(nvidia['chat_template_kwargs'], {'enable_thinking': false});

    // OpenRouter's own switch: left to think, its free models answer nothing.
    final openRouter = await bodyFor(
      LlmProvider.openRouter,
      LlmProvider.openRouter.defaultModel,
    );
    expect(openRouter['reasoning'], {'enabled': false});
    final typedIn = await bodyFor(LlmProvider.openRouter, 'some/other-model');
    expect(typedIn.containsKey('reasoning'), isFalse);

    // Gemini's default thinks little already, and rejects "none".
    final gemini = await bodyFor(
      LlmProvider.gemini,
      LlmProvider.gemini.defaultModel,
    );
    expect(gemini.containsKey('reasoning_effort'), isFalse);
  });

  test('an answer names its model as the key editor does', () async {
    final explainer = explainerAnswering(
      'Develops the bishop.',
      key: credential.copyWith(model: LlmProvider.groq.defaultModel),
    );
    addTearDown(explainer.dispose);
    final explanation = await explainer.explainMove(context);
    expect(explanation.model, LlmProvider.groq.presets.first.label);
  });

  test('every model is left room to think and still answer', () async {
    // The cap covers thinking AND answer, so a tight one returns a cut-off
    // think block (Qwen) or an empty message (gpt-oss) instead of an answer.
    for (final provider in LlmProvider.values) {
      final body = await bodyFor(provider, 'test-model');
      expect(body['max_tokens'] as int, greaterThanOrEqualTo(1000));
    }
  });

  test(
    'thinking returned in Groq\'s own field is named as the failure',
    () async {
      // gpt-oss leaves `content` empty and puts everything in `reasoning`.
      final explainer = explainerAnswering(
        '',
        groqReasoning: 'Let me analyze.',
      );
      addTearDown(explainer.dispose);

      await expectLater(
        explainer.explainMove(context),
        throwsA(isA<http.ClientException>()),
      );

      // Not "empty message", which points at the network rather than the model.
      expect(AppLog.instance.entries.last.message, contains('reasoning only'));
    },
  );

  test(
    'an unreadable answer is logged as a failure, not as an answer',
    () async {
      final explainer = OpenAiCompatExplainer(
        credential: credential,
        client: MockClient((_) async => http.Response('{"choices": []}', 200)),
      );
      addTearDown(explainer.dispose);

      await expectLater(
        explainer.explainMove(context),
        throwsA(isA<http.ClientException>()),
      );

      expect(AppLog.instance.entries.last.level, LogLevel.error);
      expect(AppLog.instance.entries.last.message, contains('no choices'));
    },
  );
}
