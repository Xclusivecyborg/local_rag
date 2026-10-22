// The question sets every measurement script shares.
//
// These used to be copy-pasted into five scripts, and they had already drifted:
// two still carried a ten-item off-topic list, missing the "Who is Cristiano
// Ronaldo?" cases added when short entity questions were rescued. A calibration
// set that differs between the script that measures a threshold and the script
// that checks it is worse than having no calibration set at all — both report a
// number, and the numbers are not comparable.
//
// The sets below are deliberately NOT merged into one. Each documented
// measurement in this project was taken against a specific set, and quietly
// widening one would invalidate the number it produced. See the note on
// [gateProbes].

/// question -> the file that genuinely contains the answer.
///
/// The original calibration set, and the baseline every hit-rate figure in the
/// README is measured against. Long, descriptive sentences, all of them.
///
/// That shape is exactly what made "Who is Tunde?" fail: a gate calibrated on
/// nothing but long sentences comes out too high for the short questions users
/// actually type. Hence [shortFormEval].
const Map<String, String> evalSet = {
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
};

/// Short, entity-shaped questions the corpus also answers.
///
/// These feed the gate calculation but deliberately NOT the hit-rate table, so
/// the model comparison stays comparable with previously recorded runs. The
/// shipping thresholds (0.47 for mxbai, 0.22 for MiniLM) were measured against
/// [evalSet] + this set = 20 on-topic questions. Adding an entry here changes
/// those numbers.
const Map<String, String> shortFormEval = {
  'Who is Tunde?': 'company_overview.md',
  'Who is Adaeze?': 'company_overview.md',
  'Who is the Operations Director?': 'company_overview.md',
  'Who are the founders?': 'company_overview.md',
  'What is the RC number?': 'company_overview.md',
  'Where is the registered office?': 'company_overview.md',
  'How much annual leave?': 'staff_handbook.md',
  'Which supplier is in Aba?': 'suppliers.md',
};

/// Long questions phrased the way a user actually typed them.
///
/// These exposed the problem query condensing exists to fix: an embedding
/// represents the whole sentence, so the extra clauses drag it off-topic.
const Map<String, String> longFormEval = {
  'How much will I get as discount if I purchase shoes worth 100,000 naira '
          'as an employee of stridewell?':
      'staff_handbook.md',
  'If I bought a pair of Heritage shoes last month and they do not fit, '
          'can I still bring them back?':
      'returns_and_warranty.md',
  'I am thinking of applying — how much time off would I actually get '
          'in my first year?':
      'staff_handbook.md',
};

/// A question asked end to end under both recipes, and how to tell a right
/// answer from its text.
class ShowcaseQuestion {
  const ShowcaseQuestion(
    this.question, {
    required this.fixedBy,
    required this.passIf,
  });

  final String question;

  /// The optimizations that make the difference. Empty for a control: a
  /// question both recipes should get right.
  final List<String> fixedBy;

  /// The answer passes if it contains any of these, ignoring case, with the
  /// ₦ sign and the separators in numbers removed.
  final List<String> passIf;

  bool passes(String answer) {
    final text = answer
        .toLowerCase()
        .replaceAll(RegExp('[\u00a0\u2009\u202f]'), ' ')
        .replaceAll('₦', '')
        .replaceAllMapped(RegExp(r'(\d)[, ](?=\d{3})'), (m) => m[1]!);
    return passIf.any((p) => text.contains(p.toLowerCase()));
  }
}

/// Questions the normal recipe gets wrong and the optimized one gets right,
/// found by asking each under both with gpt-oss, plus three controls.
///
/// Totals were computed with awk straight from sales_q1_2026.csv, not by the
/// app, so a bug in the calculation cannot also hide in the expected value.
/// No question was found where query condensing or the per-file cap is what
/// makes the difference on this knowledge base.
const List<ShowcaseQuestion> showcase = [
  ShowcaseQuestion(
    'What was our total revenue in Q1 2026?',
    fixedBy: ['Tool calling'],
    passIf: ['204740500'],
  ),
  ShowcaseQuestion(
    'What was the total revenue at Wuse 2 Abuja in January 2026?',
    fixedBy: ['Tool calling'],
    passIf: ['12819000'],
  ),
  ShowcaseQuestion(
    'Which location sold the most units in March 2026?',
    fixedBy: ['Tool calling'],
    passIf: ['453'],
  ),
  ShowcaseQuestion(
    'As a Stridewell employee, what discount would I get on a pair of Formal '
    'shoes that costs 100,000 naira?',
    fixedBy: ['Smaller chunks'],
    passIf: ['40%', '40 %', '40000', '60000'],
  ),
  ShowcaseQuestion(
    'How much did Ikeja make?',
    // Asking which period is right; so is the total over the only quarter
    // the data has.
    fixedBy: ['Strict data grounding', 'Tool calling'],
    passIf: [
      'period',
      'time frame',
      'timeframe',
      'which month',
      'which year',
      '45246500',
    ],
  ),
  ShowcaseQuestion(
    'Who is Cristiano Ronaldo?',
    fixedBy: ['Relevance filtering', 'Fine tune prompts'],
    passIf: ['football', 'portug'],
  ),
  ShowcaseQuestion(
    'What is the capital of France?',
    fixedBy: ['Relevance filtering', 'Fine tune prompts'],
    passIf: ['paris'],
  ),
  // Controls: normal RAG is not useless.
  ShowcaseQuestion(
    'How long is paternity leave?',
    fixedBy: [],
    passIf: ['two weeks', 'two (2) weeks', '2 weeks'],
  ),
  ShowcaseQuestion(
    'Who is the primary contact at Aba Leatherworks?',
    fixedBy: [],
    passIf: ['emeka okafor'],
  ),
  ShowcaseQuestion('Hello', fixedBy: [], passIf: ['hi', 'hello']),
];

/// The twelve short questions the chunk-size comparison was measured with.
///
/// Four wider than [shortFormEval] on purpose. The "10 of 12 short questions
/// retrieve at 600 characters" table in lib/document_indexing/chunker.dart is
/// this set, and flattening the two into one would silently rewrite that
/// result — the precise failure mode this file exists to prevent.
///
/// Derived from [shortFormEval] rather than restated, so adding a short
/// question there cannot update the gate calibration while leaving the
/// chunk-size table measured against a set that no longer exists. `final`
/// rather than `const` only because a spread of `.keys` is not a constant
/// expression.
final List<String> gateProbes = <String>[
  ...shortFormEval.keys,
  'Who is Tunde Balogun?',
  'When did the Abuja branch open?',
  'How many staff are part-time?',
  'What is the Heritage line?',
];

/// Things a user says that must NOT drag in documents.
///
/// The last two matter most now that short person-questions are being rescued:
/// same shape as "Who is Tunde?", but about people the corpus never mentions.
/// They are the hardest cases the gate faces, and a run without them flatters
/// the result.
const List<String> offTopic = <String>[
  'Hello',
  'hi there',
  'thanks!',
  'how are you doing today?',
  'What is the capital of France?',
  'Write me a haiku about rain',
  'who won the world cup in 2018',
  'explain recursion to me',
  'good morning',
  'ok',
  'Who is Cristiano Ronaldo?',
  'Who is Barack Obama?',
];
