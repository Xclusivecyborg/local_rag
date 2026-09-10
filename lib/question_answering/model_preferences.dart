import 'package:local_rag/ollama/ollama_client.dart';

/// Which installed models the app selects on startup, best first.
///
/// Without this the first model alphabetically would win. The embedding
/// choice matters most: an index can only be searched by the model that
/// built it, so a wrong default means re-indexing.
abstract final class ModelPreferences {
  static const List<String> chat = ['gpt-oss'];
  static const List<String> embedding = ['locusai/all-minilm-l6-v2'];

  /// The first installed model named in [preferred], ignoring its `:tag`.
  /// Falls back to the first installed model, or null if there are none.
  static String? pick(List<OllamaModel> installed, List<String> preferred) {
    if (installed.isEmpty) return null;
    for (final name in preferred) {
      for (final model in installed) {
        if (model.name == name || model.name.split(':').first == name) {
          return model.name;
        }
      }
    }
    return installed.first.name;
  }
}
