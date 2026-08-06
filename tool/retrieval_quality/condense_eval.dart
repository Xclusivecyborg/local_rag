// Does condensing the query before embedding actually help?
//
//   flutter test tool/retrieval_quality/condense_eval.dart
//
// Two things must both be true for this feature to be worth its extra model
// call: it has to fix the questions that were failing, AND it must not break
// the ones that already worked. A rewrite that strips the one distinguishing
// word from a short question is an easy way to lose ground.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/ingest.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/question_answering/query_condenser.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

import '../bench_index.dart';

const embedModel = 'mxbai-embed-large';
const chatModel = 'gpt-oss:latest';

/// The eval set, plus the real questions that exposed the problem. Phrasings a
/// user actually typed, not ones written to make the harness look good.
const Map<String, String> evalSet = {
  // --- original set -------------------------------------------------
  'How many days do I have to return unworn shoes?': 'returns_and_warranty.md',
  'What is the warranty on the Heritage line?': 'returns_and_warranty.md',
  'Can I get a refund on something I bought in a sale?':
      'returns_and_warranty.md',
  'How many people work at the company?': 'company_overview.md',
  'Where is the Abuja branch located?': 'company_overview.md',
  'When was the Port Harcourt location opened?': 'company_overview.md',
  'Who makes our Heritage leather shoes?': 'suppliers.md',
  'What are the payment terms with the Italian supplier?': 'suppliers.md',
  'Which supplier has the lowest defect rate?': 'suppliers.md',
  'How much annual leave do full-time staff get?': 'staff_handbook.md',
  'What discount do employees get on Heritage shoes?': 'staff_handbook.md',
  'What commission do staff earn on Heritage sales?': 'staff_handbook.md',
  // --- real questions that failed -----------------------------------
  'How much will I get as discount if I purchase shoes worth 100,000 naira '
      'as an employee of stridewell?': 'staff_handbook.md',
  'If I bought a pair of Heritage shoes last month and they do not fit, '
      'can I still bring them back?': 'returns_and_warranty.md',
  'I am thinking of applying — how much time off would I actually get '
      'in my first year?': 'staff_handbook.md',
};

Future<int> rankOf(
  OllamaClient ollama,
  ObjectBoxStore store,
  String query,
  String expected,
) async {
  final qv = await ollama.embedOne(
    model: embedModel,
    input: '${OllamaClient.mxbaiQueryPrefix}$query',
  );
  final ranked = store.search(qv, k: 100);
  for (var i = 0; i < ranked.length; i++) {
    if (ranked[i].chunk.source == expected) return i + 1;
  }
  return -1;
}

Future<void> _run() async {
  final ollama = OllamaClient();
  final condenser = QueryCondenser(ollama);

  stdout.writeln('Indexing sample_kb …');
  final index = await buildIndex(
    ollama: ollama,
    files: await collectFiles(Directory('sample_kb')),
    embeddingModel: embedModel,
  );
  final store = index.store;
  stdout.writeln('${store.size} chunks\n');

  var rawAt1 = 0, rawAt5 = 0, conAt1 = 0, conAt5 = 0;
  var rewritten = 0;
  final regressions = <String>[];
  final fixes = <String>[];

  for (final entry in evalSet.entries) {
    final question = entry.key;
    final expected = entry.value;

    final rawRank = await rankOf(ollama, store, question, expected);
    final condensed = await condenser.condense(
      model: chatModel,
      question: question,
      thinkingModel: true,
    );
    if (condensed.wasCondensed) rewritten++;
    final conRank =
        await rankOf(ollama, store, condensed.text, expected);

    if (rawRank == 1) rawAt1++;
    if (rawRank > 0 && rawRank <= 5) rawAt5++;
    if (conRank == 1) conAt1++;
    if (conRank > 0 && conRank <= 5) conAt5++;

    final wasIn = rawRank > 0 && rawRank <= 5;
    final nowIn = conRank > 0 && conRank <= 5;
    if (!wasIn && nowIn) fixes.add(question);
    if (wasIn && !nowIn) regressions.add(question);

    final marker = !wasIn && nowIn
        ? ' FIXED'
        : wasIn && !nowIn
            ? ' REGRESSED'
            : '';
    final short =
        question.length > 52 ? '${question.substring(0, 49)}…' : question;
    stdout.writeln('${short.padRight(53)} '
        'rank ${rawRank.toString().padLeft(3)} -> '
        '${conRank.toString().padLeft(3)}$marker');
    if (condensed.wasCondensed) {
      stdout.writeln('${' ' * 53}   "${condensed.text}"');
    }
  }

  final n = evalSet.length;
  String pct(int h) => '${(h / n * 100).round()}%';

  stdout.writeln('\n── Retrieval (n=$n, condensed $rewritten of them) ─────');
  stdout.writeln('            hit@1   hit@5');
  stdout.writeln('raw         ${pct(rawAt1).padLeft(5)}   ${pct(rawAt5).padLeft(5)}');
  stdout.writeln('condensed   ${pct(conAt1).padLeft(5)}   ${pct(conAt5).padLeft(5)}');

  stdout.writeln('\nfixed:       ${fixes.length}');
  for (final f in fixes) {
    stdout.writeln('  + ${f.length > 60 ? '${f.substring(0, 57)}…' : f}');
  }
  stdout.writeln('regressed:   ${regressions.length}');
  for (final r in regressions) {
    stdout.writeln('  - ${r.length > 60 ? '${r.substring(0, 57)}…' : r}');
  }
  if (regressions.isEmpty) {
    stdout.writeln('  (none — nothing that worked before stopped working)');
  }

  index.dispose();
  ollama.close();
}


void main() {
  test('query condensing: does it help, and what does it break?', _run,
      timeout: const Timeout(Duration(minutes: 30)));
}
