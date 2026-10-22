/// The unoptimized prompt: what a tutorial gives the model.
///
/// Used when the recipe has "Fine tune prompts" off. Nothing in it tells the
/// model what not to invent, so it answers from whatever five excerpts it
/// was handed. [OptimizedPrompt] is the tuned version.
abstract final class NormalPrompt {
  static const String system = '''
You are a helpful assistant. Answer the question using the excerpts provided.''';
}
