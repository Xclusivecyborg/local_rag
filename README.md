# Local RAG — a private assistant over your own documents

A Flutter **desktop** app that indexes a folder on your machine and lets you ask
questions about it, using models running locally through Ollama. No API keys, no
cloud, no data leaving the machine.

Built as the reference project for the FlutterBytes 2026 talk.

---

## Why desktop, and why that matters

A Flutter app on a simulator can reach `localhost` because the simulator shares
the host's network stack. On a real phone, `localhost` is the phone — and there
is no Ollama on it. Every "local RAG on Flutter" demo that runs in a simulator is
relying on that artifact.

Desktop removes the illusion. The app and the model genuinely run on the same
machine, so "local" and "offline" are literally true. The cost is that your users
must install Ollama.

## Stack

| Concern | Choice | Note |
|---|---|---|
| Inference | Ollama (`gpt-oss` by default) | REST on `127.0.0.1:11434` |
| Embeddings | `locusai/all-minilm-l6-v2` | 384-d, via Ollama |
| Vector search | ObjectBox | HNSW on disk, cosine distance |
| Aggregation | tool calling: a `calculate` tool over `CsvTable` | exact, over every row |
| Building blocks | [`rag_blocks`](../rag_blocks) | splitter, condenser, Ollama client with tool calling: pure Dart |
| Orchestration | `lib/rag/rag_pipeline.dart` | no LangChain, no Python |
| UI | Flutter macOS | streaming, citations |

There is deliberately **no Python sidecar**. Everything LangChain would have done
here is a few hundred lines of Dart, and skipping it avoids packaging a Python
runtime into a signed `.app`.

The split mirrors LangChain's. The parts that know nothing about this app live
in their own package, `rag_blocks`, which depends only on `package:http` and
runs under the plain Dart VM. It is a separate repo that sits next to this one
(`../rag_blocks`); clone both into the same folder before running `flutter pub
get`.

```dart
import 'package:rag_blocks/rag_blocks.dart';

final ollama = await OllamaClient.connect(); // starts `ollama serve` if needed

final splitter = RecursiveCharacterTextSplitter(chunkSize: 600, chunkOverlap: 200);
final chunks = splitter.splitText(text, source: 'staff_handbook.md');
```

The app composes them in `lib/rag/rag_pipeline.dart`, one numbered step at a
time, and plugs in ObjectBox as the kit's `VectorStore`.

## Running it

```bash
ollama pull locusai/all-minilm-l6-v2
ollama pull gpt-oss
flutter run -d macos
```

Then pick `sample_kb/` as your knowledge base.

Both are picked automatically at startup when installed, via
`ModelPreferences.chat` and `ModelPreferences.embedding`. Without that
list the app takes whichever model sorts first alphabetically, which is how
`gemma4` ends up beating `gpt-oss` — on spelling rather than on merit. Any
other installed model can still be chosen from the sidebar.

## Two RAGs: normal and optimized

`lib/main.dart` picks which RAG the app starts with:

```dart
var recipe = RagRecipe.normal;

// Uncomment to start with every optimization on, then hot restart.
// recipe = RagRecipe.optimized;
```

Both run through the same `RagPipeline`. A `RagRecipe` is a set of switches,
one per optimization this project measured, and the sidebar ticks off the ones
that are on:

| Switch | normal | optimized | What it fixes |
|---|---|---|---|
| `useToolCalling` | off | on | CSVs aren't embedded; the model calls a `calculate` tool that computes over every row, instead of adding up 5 chunks |
| `condenseQueries` | off | on | long questions rewritten into a short search query |
| `maxChunksPerSource` | none | 2 | no one file fills every slot (under normal, the 240-row CSV does) |
| `relevanceGate` | off | on | "Hello" gets a greeting, not the returns policy |
| `fineTunedPrompt` | off | on | `optimized_prompt.dart` forbids inventing company facts, asks for a missing detail (a year, a measure) instead of refusing, and won't estimate a total from a partial sample; normal gets `normal_prompt.dart`, the tutorial's "answer using the excerpts" |

Both recipes chunk the same way: 600 characters with 200 overlap, and markdown
a section at a time, so no chunk mixes two topics. Chunk size isn't one of the
switches because it's a trade-off to tune, not a fix: 600 retrieves more short
questions than 1200, but a 1200-character chunk sometimes holds two sections a
question needs together.

The app can also switch while it runs: the **Optimize** switch in the top
corner of the recipe card flips between normal and optimized. The conversation
stays on screen, so the same question can be asked under both. The switch is
greyed out while an answer streams or a folder is indexing.

Each recipe has its own index folder, so switching never forces a re-index once
both have been built. Switching to a recipe that has never been indexed shows a
"No … index yet" message; choose the knowledge base folder once to build it.
Before a demo, index `sample_kb/` once in each mode.

To measure the difference:

```bash
flutter test tool/retrieval_quality/before_after.dart
```

It runs both recipes through `RagPipeline.prepare` on the same questions and
writes `talk/eval/before_after.json` with every question, answer and score.

Measured 2026-10-22 on `sample_kb/` with `locusai/all-minilm-l6-v2` and
`gpt-oss`:

| | normal | optimized |
|---|---|---|
| Right file in the model's context (23 questions) | 22 | 23 |
| Right file ranked first (23) | 18 | 20 |
| Small talk answered without documents (12) | 0 | 11 |
| Showcase questions answered right (6) | 0 | 6 |
| Controls answered right (4) | 4 | 4 |
| Median time to build the prompt | 25 ms | 25 ms |

The showcase questions are in `tool/eval_set.dart`, each with the
optimizations that fix it. Three are totals over the sales CSV, which normal
can't add up from five excerpts and tool calling computes exactly. "How much
did Ikeja make?" leaves out the period, so the tuned prompt either asks for it
or answers for the only quarter there is. "Who is Cristiano Ronaldo?" and "What
is the capital of France?" are general knowledge: normal pastes in company
excerpts and then says they don't mention it, while relevance filtering and the
tuned prompt let the model just answer.

The controls (paternity leave, a supplier contact, the staff discount, "Hello")
show normal RAG isn't useless: a plain lookup in the documents works under both.
Normal's lookups look fine because it never filters, so the right file usually
rides along in its top five, with everything else. The difference is what that
costs: every "Hello" gets five excerpts pasted in, and every total is wrong.

## The evaluation harness

```bash
flutter test tool/retrieval_quality/eval.dart
```

It indexes `sample_kb/` by default; point it elsewhere with `KB=path/to/folder`.

Indexes the folder, runs a fixed question set, and reports whether the chunk
containing the answer made the top _k_. Change the chunk size or the embedding
model and re-run — you get a number instead of an impression.

Current baseline on `sample_kb/` (146 chunks, 5 files, 600-char chunks):

```
hit@1 92%   hit@3 100%   hit@5 100%   (n=12)
median retrieval latency: 27ms
```

This was `hit@1 83%` at 1200-char chunks. Always record the chunk size next to
the hit rate — the two are not independent.

There is a second script for diagnosing *why* retrieval misses, before changing
anything:

```bash
flutter test tool/retrieval_quality/experiment.dart
```

It measures score separation between real questions and chitchat, sweeps the
per-source cap, and A/Bs the query prefix.

---

## What this project is honest about

### 1. RAG cannot do arithmetic — so this app doesn't ask it to

Ask *"How much was Stridewell's revenue in January 2026?"* and retrieval hands
the model this:

```
company_overview.md      chunk 0   score 0.692
company_overview.md      chunk 1   score 0.678
sales_q1_2026.csv        chunk 6   score 0.599
sales_q1_2026.csv        chunk 3   score 0.597
returns_and_warranty.md  chunk 1   score 0.589
```

**Two CSV chunks out of forty-three** (this run was at 1200-char chunks; the
CSV is 120 of 146 chunks at the current 600, and the shape of the failure is
identical). Three slots went to files with no sales
figures in them, because prose about a footwear company scores higher against
the *words* "revenue in January" than a table of numbers does. The model dutifully
added up what it was given and answered **₦7,663,000**. The real figure is
**₦71,882,000** — off by 9.4×, and an entire week (5 January, ₦17,106,500) was
never in the context at all.

No prompt fixes this, and no value of _k_ fixes it either. Retrieval ranks by
*similarity*; aggregation needs *completeness*. Those are different operations.
Worse, `maxPerSource: 2` — the cap that fixed prose retrieval below — actively
makes this failure worse by holding the CSV to two chunks.

So structured files aren't embedded at all. With **Tool calling** on, a
CSV is loaded as a table (`CsvTable`) and the model gets a `calculate` tool,
plus a description of each table in its system prompt: the columns, the values
in each text column, and the dates covered. The model decides whether a
question needs a figure and fills in a request; code checks it and computes it
over every matching row; the model phrases the result:

```
Q: How much was Stridewell's revenue in ngn in january 2026?

  → calculate {"table": "sales_q1_2026.csv", "aggregate": "sum",
               "measure": "revenue_ngn", "from": "2026-01-01", "to": "2026-01-31"}
  ← Total revenue_ngn in January 2026: 71,882,000
    Computed over 80 matching row(s) out of 240 in sales_q1_2026.csv.

The total revenue for Stridewell Footwear in January 2026 was ₦71,882,000.

  [ badge: computed over 80 of 240 rows · sales_q1_2026.csv ]
```

The tool covers what keyword matching couldn't: "excluding Heritage" (a filter
with `is_not`), "Heritage and Formal" (several values), "weeks with at least 40
units" (a condition), "average revenue per month" (`per: month`, the average of
three monthly totals, not of 240 rows), and "which location sold the most"
(`per: location`, comparing location totals, not picking the biggest row).
Follow-ups like "and February?" work because the model has the conversation.

**The tool's most important behaviour is refusing.** A request that names a
store the table doesn't have, filters the date column, or arrives in a shape it
can't read is sent back with what's wrong ("There is no location called Ikeja.
Did you mean Ikeja City Mall?"), never run with the bad part dropped. Live,
gpt-oss once wrote a filter as the string `"location=Ikeja City Mall"`; an
early version skipped it, totalled every location, and the model still called
the figure Ikeja's. A plausible wrong number is the exact failure this feature
exists to remove.

Before tool calling, a `TableQueryPlanner` (since removed) matched
keywords in the question. Every new phrasing ("jan", "made", "excluding", "and
February?") needed another rule. The model already understands all of those;
tool calling lets it decide, while the arithmetic stays in code.

The fine-tuned prompt's rule against estimating totals still governs
excerpts, where the model *is* working from a partial sample.

### 2. Changing the embedding model moves the goalposts twice

```bash
flutter test tool/retrieval_quality/compare_embedders.dart
```

Measured on `sample_kb`, same questions, same `k=5, maxPerSource=2`:

At the shipping chunk size of **600 characters** (146 chunks):

| model | dim | hit@1 | hit@3 | hit@5 | index | query |
|---|---|---|---|---|---|---|
| `locusai/all-minilm-l6-v2` | 384 | **92%** | 100% | 100% | 661ms | **11ms** |
| `mxbai-embed-large` | 1024 | **92%** | 100% | 100% | 4115ms | 28ms |

Earlier runs at **1200 characters** (55 chunks), kept because they are the only
data on the two models since uninstalled — `MODELS=…` re-runs them after an
`ollama pull`:

| model | dim | hit@1 | hit@3 | hit@5 |
|---|---|---|---|---|
| `locusai/all-minilm-l6-v2` | 384 | 92% | 92% | 100% |
| `mxbai-embed-large` | 1024 | 83% | 100% | 100% |
| `all-minilm:22m` (L6) | 384 | 92% | 92% | 100% |
| `all-minilm:33m` (L12) | 384 | 83% | 100% | 100% |

The two tables are kept apart on purpose. Retrieval numbers are only meaningful
alongside the chunk size that produced them, and quietly merging a 1200-char
row into a 600-char table is how a README starts lying.

**Index time is not reproducible to one number.** The same model on the same
corpus took 435ms on one run and 1082ms on the next — the figure includes
Ollama loading the model into memory, so it depends on whether that model
happened to still be resident. Query time is stable and is the number to trust.
Reporting the fastest run as *the* result is how benchmarks start lying too.

The 22M-parameter MiniLM matches a model 15× its size on hit@1, embeds roughly
6× faster, answers queries 2.5× faster, and produces an index 2.7× smaller.
"Bigger embedder, better retrieval" is not a law.

`locusai/all-minilm-l6-v2` and `all-minilm:22m` are the **same model** packaged
by two different publishers. They were measured separately rather than assumed
identical, and landed on the same worst on-topic score to three decimals. That
check cost two minutes. Inheriting the other one's threshold on the assumption
they matched would have been free right up until it wasn't.

But raw similarity scores are **not comparable across models**, and that is the
part that bites:

| model | worst real question | best off-topic | gate | misses | leaks |
|---|---|---|---|---|---|
| `mxbai-embed-large` ★ | 0.478 | 0.497 | 0.47 | 0/20 | 4/12 |
| `locusai/all-minilm-l6-v2` ★ | 0.227 | 0.256 | 0.22 | 0/20 | 1/12 |

Swap to MiniLM while keeping mxbai's gate and only **5 of 20** real questions
still clear it. No exception, no warning — retrieval simply stops happening and
the assistant answers from general knowledge as if your documents were never
there.

So the threshold is a per-model map (`RetrievalSettings.measuredThresholds`), an
unmeasured model falls back to a deliberately *permissive* 0.15 — a gate set too
high silently disables retrieval, while one set too low is merely visible — and
the sidebar says so when it is guessing.

Note both rows **overlap**: the worst real question scores slightly *below* the
loudest small talk, so no single number is clean. The gate sits at the worst
real question and accepts the leaks, because a blocked question fails silently
while a leak appears on screen, labelled. `misses` and `leaks` are printed by
the calibration script so that trade is a decision rather than an accident.

### The gate is only valid for the chunk size it was measured at

These numbers were **0.57 and 0.29** until the default chunk size dropped from
1200 characters to 600. Nothing about the models changed. A shorter chunk is
about fewer things, so it matches a specific question more strongly, and every
score moves.

This was found the hard way. Asked "Who is Tunde?" — a name appearing three
times in the corpus — the app answered that it had no information about him.
The retrieval was never the problem: the correct chunk ranked **first for every
phrasing tried**, and was then discarded by a gate 0.05 above its score.

```
flutter test tool/retrieval_quality/why_did_it_miss.dart
```

At 1200 characters, one chunk of `company_overview.md` covered the founding,
the registration, the head count *and* the store locations. A chunk's vector is
an average of everything in it, and a three-word question cannot match a
four-topic average strongly. Measured across chunk sizes with 12 short
questions the documents genuinely answer:

| chunk size | short questions retrieving | canonical hit@1 |
|---|---|---|
| 1200 | **6/12** | 11/12 |
| **600** | **10/12** | 11/12 |
| 350 | 10/12 | 12/12 |

Half the knowledge base was unreachable, and nothing said so. 600 captures the
whole gain; 350 doubles the chunk count to buy one place on the canonical set.

The root cause was in the calibration set, not the code: all 12 questions were
long descriptive sentences like *"How many days do I have to return unworn
shoes?"* Not one was a short lookup. The gate was measured correctly — against
a question shape nobody types. `compare_embedders.dart` now calibrates on both
shapes, and `shortFormEval` exists so it cannot quietly regress.

**Rejected after measuring:** gating on the *margin* between the top hit and
the runner-up, on the theory that a real question has one clear winner and
small talk matches everything equally badly. It scored **18/24 against 23/24
for the plain score** — *"who won the world cup in 2018"* had a bigger lead
over its runner-up than most real questions. `tool/retrieval_quality/gate_shape.dart`
is the measurement that killed it.

### The chunker, next to LangChain's

`chunkDocument` is the same shape as LangChain's `RecursiveCharacterTextSplitter`
and deliberately not its `CharacterTextSplitter`. The difference is what happens
when the separator does not appear. Hand each of them one 1,524-character
paragraph containing no blank line, asking for 600:

```
CharacterTextSplitter:          1 chunk,  sizes [1524]        ← plus a warning
RecursiveCharacterTextSplitter: 4 chunks, sizes [599, 598, 589, 314]
ours:                           3 chunks, sizes [548, 599, 599]
```

`CharacterTextSplitter` has exactly one rule, `"\n\n"`, and shrugs when it does
not apply. `_splitIntoBlocks` walks a ladder instead — paragraph, then sentence,
then a hard character cut — which is the recursive splitter's idea written out
longhand.

**Where this one is better: overlap is a target, not a ceiling.** LangChain
builds overlap by keeping whole trailing splits while their combined length
stays under the budget. If the last paragraph of a chunk is bigger than the
budget it is dropped entirely and that boundary gets *no overlap at all*.
Characters actually carried across each boundary of `company_overview.md` at
600/200:

| boundary | 0→1 | 1→2 | 2→3 | 3→4 | 4→5 | 5→6 |
|---|---|---|---|---|---|---|
| LangChain (both splitters) | 29 | 191 | 58 | **0** | 16 | — |
| this | 192 | 192 | 119 | 195 | 197 | 198 |

The whole point of overlap is that a fact straddling a boundary survives whole
somewhere. A boundary that silently gets zero does not do that.

**Where it was worse, until it was measured.** LangChain never exceeds the size
you ask for. This did: the overlap tail was written into the buffer the moment a
chunk was emitted, and the next block went in with no size check, so a chunk
could reach `targetChars + overlapChars`. Measured at 667 against a 600 target
on the real corpus, and 802 on input with nothing to break on. The tail is now
held back until the next block is known and trimmed to whatever fits — which is
why one boundary above carries 119 instead of ~195. That is the trade, and it is
the right way round: a slightly thinner overlap is visible in a table, an
oversized chunk is not.

Re-measuring afterwards found both retrieval gates unchanged, and MiniLM's worst
real question *improved* from 0.221 to 0.227 — a chunk no longer allowed to run
over is a chunk about slightly fewer things.

**Still missing, on purpose:** counting length in tokens rather than characters.
LangChain's `length_function` takes a tokenizer; 600 characters here is a guess
at ~150 tokens, and embedding models truncate on tokens. Ollama exposes no
tokenizer over HTTP, so this would mean bundling one. Not worth it yet.

### 3. Changing the embedding model also invalidates the whole index

Vectors are only comparable to vectors from the same model. Swap the embedder and
every stored vector becomes meaningless — same numbers, different space. If the
dimension also changes you get an exception, which is the *lucky* case; if it
happens to match, you get plausible nonsense with no error at all.

So the index persists `embeddingModel` and `dimension` alongside the vectors, and
refuses to load against a mismatch (`ObjectBoxStore.isCompatibleWith`).

### 4. A bad retrieval is usually a corpus problem, not a model problem

The first eval run missed several questions, and the obvious suspect was the
embedding model. It wasn't. Measuring it took one script:

| index | hit@1 | hit@3 |
|---|---|---|
| full corpus, 55 chunks | 83% | 92% |
| **CSV excluded, 12 chunks** | **92%** | **100%** |

Measured at 1200-char chunks. Same embedder, same questions. The 240-row sales
CSV became 43 of 55 chunks that all mention the same locations and product
lines, and it crowded out the prose. Swapping embedding models would have cost
an afternoon and fixed nothing. At the current 600-char chunks the imbalance is
worse in absolute terms — 120 of 146 — which is why the cap matters more, not
less. The optimized recipe no longer embeds the CSV at all (see section 1), so
there the cap guards against any one long document instead.

The fix was a cap on how many chunks any one file may contribute to the top _k_
(`ObjectBoxStore.search(maxPerSource:)`). Sweeping it:

```
cap none    hit@1 83%  hit@3 92%
cap 3       hit@1 83%  hit@3 92%
cap 2       hit@1 83%  hit@3 100%     ← in use
cap 1       hit@1 83%  hit@3 100%
```

hit@1 is unmoved — two questions still rank a near-miss first — but the app
passes all five chunks to the model, so what matters is that the answer is
*present*, and at cap 2 it always is.

---

## Gotchas worth knowing

**Entitlements live in two files.** Whatever you decide about the sandbox,
`DebugProfile.entitlements` and `Release.entitlements` must agree. Changing only
the debug one is the classic mistake: everything works all through development
and breaks the first time you ship a release build.

**Some entitlements are read by packages, not by the OS.** Turning the sandbox
off makes `com.apple.security.files.user-selected.read-only` look redundant —
without a sandbox there is nothing to relax. Remove it and the folder picker
breaks with `PlatformException(ENTITLEMENT_NOT_FOUND)`, because `file_picker`
checks for that key itself with `SecTaskCopyValueForEntitlement` and never asks
whether the app is sandboxed. Treat entitlements as a manifest your dependencies
may read, not only as permissions the kernel enforces.

**Wrap plugin calls that can throw.** The picker failure surfaced only as an
unhandled async error — visible in a debugger, invisible in a release build,
where the button would simply do nothing. `PlatformException` from a plugin
belongs in the UI like any other error.

**`capabilities`, not `embedding_length`.** `/api/tags` reports an
`embedding_length` for chat models too — it's their internal hidden size (2880 for
`gpt-oss`). Filtering on it will offer you a chat model as an embedder. Filter on
`capabilities` containing `embedding`.

**mxbai is asymmetric — but measure before you believe it.** The documented
advice is that queries take the prefix
`Represent this sentence for searching relevant passages: ` while stored passages
do not. On this corpus it made **no measurable difference** (83%/92% either way).
It's kept because it's free and may matter at larger scale, but it is not doing
work here. Don't cargo-cult retrieval tricks — A/B them.

**Reasoning models stream `thinking` before `content`.** `gpt-oss` emits a
scratchpad first. Render only `content` and the UI looks frozen for several
seconds on every question.

**Don't stream tokens through `setState`.** Tokens arrive dozens of times a
second; a top-level rebuild redraws the sidebar and every previous message each
time. The live bubble sits behind a `ValueNotifier` + `ValueListenableBuilder` so
only it repaints.

## Starting Ollama, and the sandbox decision behind it

The app runs `ollama serve` for you on launch. That one sentence costs more than
it looks.

**The App Sandbox forbids spawning executables outside your own bundle.** So the
obvious implementation is denied before it runs, and it fails as a generic
exception rather than anything that says "permission". There are two ways out:

| | Sandboxed | Not sandboxed |
|---|---|---|
| Start `ollama serve` | impossible | `Process.start` |
| Start Ollama.app | `NSWorkspace`, via a platform channel | also fine |
| Works with a Homebrew-only install | no | yes |
| Mac App Store | yes | no |

This project takes the second column: **the sandbox is off** (see
`macos/Runner/DebugProfile.entitlements`, which explains what to restore if you
want it back). The deciding argument is that plenty of people install Ollama with
`brew install ollama` and never have an `Ollama.app` to open at all — the
sandboxed route simply cannot serve them.

Worth knowing on macOS: a standard ollama.com install makes `/usr/local/bin/ollama`
a **symlink into the app bundle**. Deleting Ollama.app also removes your terminal
`ollama`. Homebrew installs are genuinely independent.

**A GUI app does not inherit your shell's PATH.** It gets
`/usr/bin:/bin:/usr/sbin:/sbin`. `which ollama` working in Terminal tells you
nothing about whether your app can find it, so `OllamaLauncher.defaultSearchPaths()`
lists install locations explicitly instead of searching PATH.

**Detached means fully detached.** `ProcessStartMode.detachedWithStdio` looks
strictly better — the process outlives you *and* you get stderr for diagnostics.
It doesn't. The child's stdio stays wired to pipes the parent owns; quit the app
and Ollama dies on its next write. Measured: it survived ~3 seconds. Plain
`ProcessStartMode.detached` sends stdio to `/dev/null` and genuinely survives,
and the price is that a failed start can't explain itself — so every failure
message hands the user back to `ollama serve` in a terminal, which can.

The sequence, once all that is settled:

```
probe /api/version ──► answers? ──► done, nothing started
        │
        └─ no ──► find binary ──► Process.start(detached) ──► poll /api/version
                                                              every 400ms, ≤30s
```

Probing first matters: a healthy Ollama is never touched, so the app never
starts a second server or disturbs one you're using from your own terminal.

**Stopping is an explicit action, never a side effect.** The sidebar has Stop
and Connect, and quitting the app stops nothing. Ollama has no shutdown
endpoint, so Stop is a signal — the same thing `pkill ollama` does — SIGTERM
first so it can close its model files cleanly, escalating to SIGKILL only if
that is ignored. Stopping `ollama serve` also takes down the per-model
`llama-server` children, because they are its children rather than ours.

Two details that matter more than they look:

- **Stop targets whatever is serving, not just what we started.** It prefers the
  pid we spawned, then falls back to `pgrep -f "ollama serve"`. A Stop button
  that only stopped *our* copy would be a lie the first time you started Ollama
  in a terminal yourself.
- **The port is the verdict, not the exit code.** A dead pid does not prove the
  service stopped, so both start and stop poll `/api/version` until it agrees.

## Conversation, and knowing when *not* to retrieve

A basic RAG app injects five document chunks into every request. Say "Hello" and
it either errors or answers your greeting with the returns policy.

This one always searches, but only *uses* the result when the top score clears a
threshold. Below it, the excerpts are dropped and the model answers normally —
so general knowledge, small talk and company questions all work in one chat.

The threshold is measured, not guessed
(`tool/retrieval_quality/compare_embedders.dart`):

```
real questions       min 0.227   (20 questions, long and short form)
off-topic chitchat   max 0.256   ("how are you doing today?")
                                  → gate 0.22, misses 0, leaks 1 of 12
```

The two bands overlap, so the gate is a choice rather than a reading: sit at
the worst real question and let the noisiest small talk through, because a
blocked question fails silently and a leak does not.

The number is **not portable**. A different embedding model, a different
corpus, *or a different chunk size* needs a fresh measurement — see above for
what happened when only the chunk size changed.

Two supporting details:

- **There are two prompts, side by side.** `normal_prompt.dart` is the one line
  a tutorial gives; `optimized_prompt.dart` is the tuned prompt, split into the
  sections each switch turns on. With Fine tune prompts on, the model is told
  never to invent company facts, and to ask for a missing detail rather than
  refuse. When excerpts were retrieved, it is also told to prefer them, cite
  the file, and not estimate totals from them. With Tool calling and CSV files
  indexed, the calculate tool's rules and a description of every table are
  added at the end.
- **History is replayed clean.** The last 8 turns go into the request, but
  retrieved excerpts attach only to the current question and are never written
  into history — otherwise stale context from three questions ago keeps steering
  answers and the window fills with duplicates.

Every answer is labelled in the UI with whether it came from your documents or
from general knowledge, plus the score and the gate, so the mechanism is visible
rather than magic.

## Rendering the model's Markdown

Models emit Markdown whether you asked for it or not — `**bold**`, headings,
bullets, fenced code. Rendered as plain text it looks like debug output.

`lib/ui/markdown_text.dart` is a ~300-line renderer covering what actually shows up
in chat: bold, italic, inline code, strikethrough, headings, bullet and numbered
lists, block quotes, fenced code. No dependency — `flutter_markdown` is
discontinued, and hand-rolling the inline parser is what makes the next two
points possible.

**Streaming needs different rules than a file.** Mid-stream the buffer says
`Hello, My name is **Jam`. A conformant parser renders those asterisks
literally, so the user watches `**Jam` appear and then snap into bold a frame
later — on every bold run, in every message. Here an unclosed `**` styles the
remainder instead, and the word simply arrives already bold. There's a test that
walks every prefix of a sentence and asserts a literal `*` is never visible.

**Underscores are not emphasis.** `_foo_` renders literally. Real content is
full of `revenue_ngn` and `all-MiniLM-L6-v2`, and treating `_` as italic
silently mangles them. Models use `*` for emphasis almost exclusively.

Selection is one `SelectionArea` around the whole transcript rather than a
`SelectableText` per bubble — rendered Markdown is many widgets, and per-widget
selection stops dead at every bold run.

## Layout

Folders are named for what the code in them does, and `test/` mirrors `lib/`.

```
lib/
  main.dart                    desktop UI (Flutter's entry point; must live here)
  libobjectbox.dylib           native lib for `flutter test` (gitignored)

  rag/                         the workflow: this app's RAG, step by step
    rag_recipe.dart            the switches, and the normal / optimized presets
    rag_pipeline.dart          ingest (load, chunk, embed, store; CSVs become tables), prepare (retrieve, gate, prompt), generate (run tool calls)
    markdown_sections.dart     splits a markdown file before each heading
    calculate_tool.dart        the calculate tool: describes the CSV tables, checks the model's requests, computes exact figures
    normal_prompt.dart         the unoptimized prompt: a tutorial's one line
    optimized_prompt.dart      the optimized prompt, in sections per switch
    rag_prompts.dart           puts the system prompt together from those two
    retrieval_settings.dart    top-k, per-file cap, measured per-model gates

  tables/
    csv_table.dart             CsvTable: exact totals, averages and breakdowns over every row

  vector_search/               storing vectors and finding the nearest ones
    objectbox_store.dart       the index: ObjectBox HNSW on disk, a rag_blocks VectorStore
    vectors.dart               normalising, and the padding rules
    vector_entities.dart       one entity per embedding dimension
    objectbox.g.dart           generated (see `objectbox:` in pubspec.yaml)
    objectbox-model.json       generated: entity/property UID history

  question_answering/          feeding the pipeline and streaming its answers
    rag_controller.dart        state, connection, indexing, streaming, stop
    model_preferences.dart     which installed models to start on

  ui/                          widgets, one per file
    app.dart                   MaterialApp
    theme/app_theme.dart       the dark theme, fixed-meaning colours, the mono face
    widgets/panel.dart         shared parts: Panel, IconTile, Tag, StatusDot, PanelHeader
    home_page.dart             the three-pane layout and folder picking
    composer.dart              the input box, send/stop, and which recipe will answer
    markdown_text.dart         streaming-safe Markdown renderer
    sidebar/                   the left configuration panel
      sidebar.dart             assembles the panel
      recipe_card.dart         which recipe is running, and its optimizations
      section_label.dart       small caps heading
      model_dropdown.dart      chat / embedding model pickers
      connection_card.dart     Ollama state, Connect and Stop
      index_status.dart        indexing progress, and what got indexed
      error_card.dart          anything that went wrong
    transcript/                the conversation view
      transcript.dart          the scrolling list
      empty_state.dart         first-run guidance, and one-click example questions
      turn_bubble.dart         one finished message
      streaming_bubble.dart    the in-flight message and its thinking pane
      citations.dart           source chips, and the retrieved-vs-computed badge

tool/
  bench_index.dart             shared: build a throwaway index from a folder
  eval_set.dart                shared: the question sets, defined once
  retrieval_quality/           does retrieval find the right chunk?
    eval.dart                  hit-rate harness
    experiment.dart            score separation, cap sweep, prefix A/B
    compare_embedders.dart     head-to-head: hit rate, cost, per-model gate
    gate_shape.dart            can the gate pass short questions but not chitchat?
    why_did_it_miss.dart       post-mortem: full top-5 for one failing question
    condense_eval.dart         does query condensing help, and what does it break?
    before_after.dart          normal vs optimized recipe, written to talk/eval/
  ui_preview/
    app_preview.dart           renders the app's screens to PNGs, no screen recording needed
    talk_shots.dart            extra screens for the slides, rendered the same way
  index_benchmarks/            which vector backend, and from what corpus size?
    obx_bench.dart             build time, query latency and size vs corpus size

../rag_blocks/                 the building blocks, pure Dart, in their own repo
  lib/src/
    document_loaders/          findSupportedFiles
    text_splitters/            RecursiveCharacterTextSplitter: paragraphs, sentences, overlap
    document_transformers/     csvToProse, and parseCsvGrid underneath it
    query_transformers/        QueryCondenser: rewrites long questions before embedding
    llms/                      OllamaClient: connect(), chat() / chatStream() with tools, embed(), listModels()
                               Tool, ToolCall, ChatMessage: tool calling
                               OllamaLauncher: finds the ollama binary, starts it detached, stops it
    vector_stores/             the VectorStore interface, InMemoryVectorStore, StoredChunk, ScoredChunk
    retrievers/                SimilarityRanker, capPerSource

sample_kb/                     sample business knowledge base
```

### Tests

247 total: 139 in the app, 108 in `rag_blocks`. `conversation_test.dart` and `index_directory_test.dart` need Ollama
running; both skip themselves if it is unreachable.

Every script in `tool/` runs under `flutter test`, not `dart run` — the
generated `objectbox.g.dart` imports `objectbox_flutter_libs`, so anything
reaching the index pulls in Flutter and the plain Dart VM cannot compile it.

| file | what it covers |
|---|---|
| `vector_search/objectbox_store_test.dart` | search, per-source cap, persistence, the wrong-size-vector footgun |
| `vector_search/padding_test.dart` | that zero-padding leaves cosine similarity exactly unchanged |
| `question_answering/index_directory_test.dart` | the real indexing path: build, persist, reload, re-index |
| `question_answering/recipe_switch_test.dart` | the Optimize switch: each recipe opens its own index, the "no index yet" message, the conversation is kept, no switching mid-answer |
| `rag/rag_pipeline_test.dart` | what each recipe switch changes: the gate, condensing, CSV embedded or kept as a table, tool calls, a retry when a call can't be read |
| `question_answering/retrieval_threshold_test.dart` | per-model gates, and a tripwire that fails if the chunk size changes without re-measuring them |
| `question_answering/default_model_test.dart` | which model the app starts on when several are installed |
| `question_answering/conversation_test.dart` | integration against a live model, incl. the January question answering 71,882,000 through the calculate tool, not 7,663,000 |
| `ui/markdown_test.dart` | renderer, including every streaming prefix |
| `tables/table_test.dart` | exact arithmetic vs independently computed ground truth, for every kind of query |
| `rag/calculate_tool_test.dart` | the tool's schema and table description, the spellings models use, and every request it refuses |

In `rag_blocks/test/`, run with `dart test` from that repo:

| file | what it covers |
|---|---|
| `recursive_character_text_splitter_test.dart` | paragraph splitting, overlap, the size ceiling, source offsets incl. CRLF files |
| `csv_to_prose_test.dart` | CSV rendered as labelled prose |
| `query_condenser_test.dart` | when to rewrite, and every way a rewrite is rejected |
| `ollama_client_test.dart` | `chat` waits for the whole reply, `chatStream` yields pieces, errors are thrown, tools are sent and tool calls read back |
| `directory_loader_test.dart` | supported files found in subfolders, hidden ones skipped |
| `similarity_ranker_test.dart` | closest first, `top`, `maxPerSource`, `minScore` |
| `in_memory_vector_store_test.dart` | cosine similarity, closest first, the per-file cap |
| `ollama_launcher_test.dart` | paths a working machine never reaches: no binary, dangling symlink, failed spawn, start timeout, SIGTERM/SIGKILL escalation, a server we did not start, the menu-bar app that restarts its server |

## Not handled

PDFs (text or scanned), Word documents, images, and incremental re-indexing —
changing one file re-embeds the whole folder.

## Vector search: one index, and the one it beat

ObjectBox's HNSW graph is the only index. It was chosen against an exact
brute-force scan that has since been removed, and the comparison is worth
recording because it is the evidence the choice rests on: measured on real
embeddings, both embedding models, the full eval set, the two returned
**identical top-5 results on 12 of 12 questions** with similarity scores
agreeing to seven decimal places, and recall@5 stayed at 98–100% out to 8,000
chunks. The crossover was around **500 chunks** — below it the exact scan was
marginally faster, above it HNSW is flat in corpus size while a linear scan
grows: 36× faster at 8,000 chunks with all-MiniLM, 59× with mxbai.

Those recall figures can no longer be re-run: recall means "how much of the exact
answer did the approximation find", and there is no longer an exact index to
ask. `obx_bench.dart` now measures build time, query latency, disk size, and
hit@k — the last of which is scored against the document known to contain the
answer, so it needs no second index.

**Spreadsheet rows get their own index.** Rows from one CSV read almost alike,
and in a graph shared with the documents that cluster traps the search. Built
with `sales_q1_2026.csv` ahead of `staff_handbook.md` (alphabetical, the order
`findSupportedFiles` returns), "How much annual leave?" got only sales rows back
in 4 of 5 builds, even at k=40, though the handbook scores 0.635 against the
rows' best 0.307. Raising ObjectBox's `neighborsPerNode` to 64 and
`indexingSearchCount` to 200 only cut that to 2 of 8. So `ObjectBoxStore` keeps
two HNSW indexes, `documents/` and `tables/`, searches both and merges by score:
8 of 8 builds then ranked the handbook first, on default settings. Measured
2026-10-19. An earlier build hid this behind a full scan below 500 chunks,
which doesn't scale and was removed. Only the normal recipe still embeds
spreadsheet rows; with tool calling the `tables/` index stays empty.

### Two ObjectBox things worth knowing

**`@HnswIndex(dimensions:)` is fixed at code-generation time.** Unlike Chroma or
Qdrant, where a collection's width is a runtime argument, this build can only
store the widths declared in `lib/vector_search/vector_entities.dart` — 384, 768
and 1024. Narrower models are **zero-padded** up to the nearest, which leaves
cosine similarity *exactly* unchanged: appending zeros adds only `0 * 0` terms
to the dot product and moves neither magnitude. So every model up to 1024-d
works, at the cost of some wasted storage. Anything wider fails with an error
naming the file to edit. The property is tested directly in
`test/vector_search/padding_test.dart`, because the entire scheme collapses if
it is even slightly false.

**ObjectBox does not validate vector length.** Put a 1024-d vector into a 384-d
index and it is accepted silently; the index is quietly wrong from then on.
`ObjectBoxStore.addAll` checks before every write.

### Running the tests

`flutter test` needs `lib/libobjectbox.dylib`, which is gitignored — the app
itself gets `ObjectBox.framework` from CocoaPods, but the test runner is a plain
Dart VM on the host and only looks in `<cwd>/lib`. Fetch it once:

```bash
bash <(curl -s https://raw.githubusercontent.com/objectbox/objectbox-dart/main/install.sh)
```

ObjectBox requires **macOS 11.0**, so the deployment target moved up from 10.15.
