import 'package:flutter_test/flutter_test.dart';
import 'package:rag_blocks/rag_blocks.dart';
import 'package:local_rag/question_answering/model_preferences.dart';

OllamaModel model(String name) =>
    OllamaModel(name: name, capabilities: const ['completion']);

/// Installed models arrive sorted by name, so anything relying on order is
/// really relying on spelling. These lists are in that sorted order on purpose.
void main() {
  group('which model the app starts on', () {
    test('a preferred model wins over one that merely sorts earlier', () {
      final installed = [model('gemma4:latest'), model('gpt-oss:latest')];
      expect(
        ModelPreferences.pick(installed, ModelPreferences.chat),
        'gpt-oss:latest',
      );
    });

    test('the preference ignores the tag', () {
      final installed = [model('gemma4:latest'), model('gpt-oss:20b')];
      expect(
        ModelPreferences.pick(installed, ModelPreferences.chat),
        'gpt-oss:20b',
        reason: 'a preference for gpt-oss must not require the :latest tag',
      );
    });

    test('preference order decides when several are installed', () {
      final installed = [model('alpha:latest'), model('beta:latest')];
      expect(ModelPreferences.pick(installed, ['beta', 'alpha']), 'beta:latest');
      expect(ModelPreferences.pick(installed, ['alpha', 'beta']), 'alpha:latest');
    });

    test('falls back to the first installed model when none is preferred', () {
      // A machine with neither gpt-oss nor anything else on the list must
      // still start usable rather than with an empty dropdown.
      final installed = [model('gemma4:latest'), model('llama3:latest')];
      expect(
        ModelPreferences.pick(installed, ModelPreferences.chat),
        'gemma4:latest',
      );
    });

    test('no models installed is null, not a crash', () {
      expect(
        ModelPreferences.pick(const [], ModelPreferences.chat),
        isNull,
      );
    });

    test('a partial name does not count as a match', () {
      // 'gpt-oss' must not be satisfied by 'gpt-oss-abliterated', which is a
      // different model with different behaviour.
      final installed = [model('gpt-oss-abliterated:latest')];
      expect(
        ModelPreferences.pick(installed, ModelPreferences.chat),
        'gpt-oss-abliterated:latest',
        reason: 'it is the only model, so it is chosen as the fallback — but '
            'as a fallback, not as a preference match',
      );
      final withOther = [
        model('gemma4:latest'),
        model('gpt-oss-abliterated:latest'),
      ];
      expect(
        ModelPreferences.pick(withOther, ModelPreferences.chat),
        'gemma4:latest',
        reason: 'no real gpt-oss present, so the fallback is first-sorted',
      );
    });
  });
}
