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
| Aggregation | `CsvTable` + planner | exact, over every row |
| Orchestration | Plain Dart | no LangChain, no Python |
| UI | Flutter macOS | streaming, citations |

There is deliberately **no Python sidecar**. Everything LangChain would have done
here is a few hundred lines of Dart, and skipping it avoids packaging a Python
runtime into a signed `.app`.

## Running it

```bash
ollama pull locusai/all-minilm-l6-v2
ollama pull gpt-oss
flutter run -d macos
```

Then pick `sample_kb/` as your knowledge base.

Both are picked automatically at startup when installed, via
`RagController.preferredChatModels` and `preferredEmbedModels`. Without that
list the app takes whichever model sorts first alphabetically, which is how
`gemma4` ends up beating `gpt-oss` — on spelling rather than on merit. Any
other installed model can still be chosen from the sidebar.

## The evaluation harness

```bash
flutter test tool/retrieval_quality/eval.dart sample_kb
```

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

## Four things this project is honest about

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

So structured files are parsed **twice**: into prose for semantic lookup, and
into a real table (`CsvTable`) for arithmetic. Before retrieval runs,
`TableQueryPlanner` decides whether the question is an aggregation over that
table. If it is, the answer is *computed over every matching row* and the model
is handed the finished figure to phrase rather than raw rows to add up:

```
Q: How much was Stridewell's revenue in ngn in january 2026?

Stridewell's revenue in NGN for **January 2026** was **71,882,000**.
- **Period covered:** January 2026
- **Metric:** Total `revenue_ngn`
- **Data source:** Computed over 80 matching rows out of 240 in sales_q1_2026.csv.

  [ badge: computed over 80 of 240 rows · sales_q1_2026.csv ]
```

**The planner's most important behaviour is refusing.** *"How much annual leave
do full-time staff get?"* contains "how much", but no numeric column matches
"leave" — so it declines and retrieval handles it. A planner that always
produces something would answer that question with a sales figure. Ambiguity is
declined too: if a question matches `revenue_ngn` and `unit_price_ngn` equally,
it returns null rather than flipping a coin, because a plausible wrong number is
the exact failure this feature exists to remove.

Retrieval and computation are mutually exclusive per turn, and the UI badge says
which one answered. "5 of 43 chunks" and "80 of 240 rows" deserve very different
amounts of trust.

The **Strict grounding** switch still governs the retrieval path, where the model
*is* working from a partial sample. It is deliberately not applied to computed
answers — telling a model to warn about incomplete data when the figure covers
every row makes it undermine a number that is exact.

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
| `mxbai-embed-large` ★ | 0.478 | 0.500 | 0.47 | 0/20 | 4/12 |
| `locusai/all-minilm-l6-v2` ★ | 0.221 | 0.249 | 0.22 | 0/20 | 1/12 |

Swap to MiniLM while keeping mxbai's gate and only **5 of 20** real questions
still clear it. No exception, no warning — retrieval simply stops happening and
the assistant answers from general knowledge as if your documents were never
there.

So the threshold is a per-model map (`RagController.measuredThresholds`), an
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
less.

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

A naive RAG app injects five document chunks into every request. Say "Hello" and
it either errors or answers your greeting with the returns policy.

This one always searches, but only *uses* the result when the top score clears a
threshold. Below it, the excerpts are dropped and the model answers normally —
so general knowledge, small talk and company questions all work in one chat.

The threshold is measured, not guessed
(`tool/retrieval_quality/compare_embedders.dart`):

```
real questions       min 0.221   (20 questions, long and short form)
off-topic chitchat   max 0.249   ("how are you doing today?")
                                  → gate 0.22, misses 0, leaks 1 of 12
```

The two bands overlap, so the gate is a choice rather than a reading: sit at
the worst real question and let the noisiest small talk through, because a
blocked question fails silently and a leak does not.

The number is **not portable**. A different embedding model, a different
corpus, *or a different chunk size* needs a fresh measurement — see above for
what happened when only the chunk size changed.

Two supporting details:

- **The system prompt changes shape** depending on whether context was retrieved.
  With excerpts it is told to prefer them and cite the file; without, it is just
  an assistant. Both versions forbid inventing company facts.
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

`lib/markdown_text.dart` is a ~300-line renderer covering what actually shows up
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

  ollama/                      starting and talking to the local model server
    ollama_client.dart         /api/tags, /api/embed, /api/chat (NDJSON stream)
    ollama_launcher.dart       finds the ollama binary and starts it, detached

  document_indexing/           files in, embedded chunks out
    chunker.dart               paragraph-aware splitting with overlap
    ingest.dart                file reading, CSV to prose, batch embedding

  vector_search/               storing vectors and finding the nearest ones
    objectbox_store.dart       the index: ObjectBox HNSW on disk
    stored_chunk.dart          chunk/score types, and the padding rules
    vector_entities.dart       one entity per embedding dimension
    objectbox.g.dart           generated (see `objectbox:` in pubspec.yaml)
    objectbox-model.json       generated: entity/property UID history

  table_arithmetic/            exact totals over rows, where retrieval cannot
    csv_table.dart             CSV as a table: typed columns, exact aggregation
    table_query_planner.dart   question -> TableQuery, or null (refusing is the point)

  question_answering/          turning a question into a grounded answer
    query_condenser.dart       rewrites long questions before embedding
    rag_controller.dart        state, connection, retrieval gating, prompt assembly

  ui/                          widgets, one per file
    app.dart                   MaterialApp and theme
    home_page.dart             the three-pane layout and folder picking
    composer.dart              the input box and send/stop
    markdown_text.dart         streaming-safe Markdown renderer
    sidebar/                   the left configuration panel
      sidebar.dart             assembles the panel
      section_label.dart       small caps heading
      model_dropdown.dart      chat / embedding model pickers
      connection_card.dart     Ollama state, Connect and Stop
      index_status.dart        indexing progress, and what got indexed
      error_card.dart          anything that went wrong
    transcript/                the conversation view
      transcript.dart          the scrolling list
      empty_state.dart         first-run guidance
      turn_bubble.dart         one finished message
      streaming_bubble.dart    the in-flight message and its thinking pane
      citations.dart           source chips, and the retrieved-vs-computed badge

tool/
  bench_index.dart             shared: build a throwaway index from a folder
  retrieval_quality/           does retrieval find the right chunk?
    eval.dart                  hit-rate harness
    experiment.dart            score separation, cap sweep, prefix A/B
    compare_embedders.dart     head-to-head: hit rate, cost, per-model gate
    condense_eval.dart         does query condensing help, and what does it break?
  index_benchmarks/            which vector backend, and from what corpus size?
    obx_bench.dart             build time, query latency and size vs corpus size

sample_kb/                     sample business knowledge base
```

### Tests

122 total. `conversation_test.dart` and `index_directory_test.dart` need Ollama
running; both skip themselves if it is unreachable.

Every script in `tool/` runs under `flutter test`, not `dart run` — the
generated `objectbox.g.dart` imports `objectbox_flutter_libs`, so anything
reaching the index pulls in Flutter and the plain Dart VM cannot compile it.

| file | what it covers |
|---|---|
| `document_indexing/chunker_test.dart` | paragraph splitting, overlap, edge cases |
| `document_indexing/csv_to_prose_test.dart` | CSV rendered as labelled prose |
| `vector_search/objectbox_store_test.dart` | search, per-source cap, persistence, the wrong-size-vector footgun |
| `vector_search/padding_test.dart` | that zero-padding leaves cosine similarity exactly unchanged |
| `question_answering/index_directory_test.dart` | the real indexing path: build, persist, reload, re-index |
| `table_arithmetic/table_test.dart` | exact arithmetic vs independently computed ground truth, and every case the planner must decline |
| `question_answering/condenser_test.dart` | when to rewrite, and every way a rewrite is rejected |
| `question_answering/retrieval_threshold_test.dart` | per-model gates |
| `question_answering/conversation_test.dart` | integration against a live model, incl. the January question answering 71,882,000 not 7,663,000 |
| `ollama/launcher_test.dart` | paths a working machine never reaches: no binary, dangling symlink, failed spawn, start timeout, SIGTERM/SIGKILL escalation, a server we did not start |
| `ui/markdown_test.dart` | renderer, including every streaming prefix |

## Not handled

PDFs (text or scanned), Word documents, images, and incremental re-indexing —
changing one file re-embeds the whole folder.

**Query condensing** is the notable gap. Follow-ups work because history is
replayed to the *model*, but retrieval still embeds the raw question. Ask "and
the Abuja one?" and the search sees only those four words. Condensing the
question against history before embedding is the standard fix.

## Vector search: two backends

ObjectBox's HNSW graph is the only index. It was chosen against an exact
brute-force scan that has since been removed, and the comparison is worth
recording because it is the evidence the choice rests on: measured on real
embeddings, both embedding models, the full eval set, the two returned
**identical top-5 results on 12 of 12 questions** with similarity scores
agreeing to seven decimal places, and recall@5 stayed at 98–100% out to 8,000
chunks. The crossover was around **500 chunks** — below it the exact scan was
marginally faster, above it HNSW is flat in corpus size while a linear scan
grows: 36× faster at 8,000 chunks with all-MiniLM, 59× with mxbai.

Full numbers in [`talk/objectbox-phase0.md`](talk/objectbox-phase0.md),
including the two benchmark mistakes that produced wrong answers first. Those
recall figures can no longer be re-run: recall means "how much of the exact
answer did the approximation find", and there is no longer an exact index to
ask. `obx_bench.dart` now measures build time, query latency, disk size, and
hit@k — the last of which is scored against the document known to contain the
answer, so it needs no second index.

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
