# Demo questions

Ask each question with the **Optimize** switch off (normal RAG), then flip it
on and ask again. The conversation stays on screen, so the room sees both
answers side by side.

These are the questions from `tool/eval_set.dart`. What each recipe says below
is from the last eval run (2026-10-22, MiniLM and gpt-oss), recorded in full in
`eval/before_after.json`. gpt-oss words its answers a little differently each
time, but the right or wrong part held.

Before the talk, index `sample_kb/` once under each recipe.

## Normal gets these wrong, optimized gets them right

| # | Question | Normal RAG | Optimized RAG | What fixes it |
|---|---|---|---|---|
| 1 | Hello | Answers, but five company excerpts were pasted into the prompt first | A plain greeting, with no documents | Relevance filtering |
| 2 | What is the capital of France? | "None of the provided excerpts contain information about France" | Paris | Relevance filtering, Fine tune prompts |
| 3 | Who is Cristiano Ronaldo? | Says the excerpts don't mention him | Portuguese footballer | Relevance filtering, Fine tune prompts |
| 4 | What was our total revenue in Q1 2026? | Says the excerpts have no revenue figures | ₦204,740,500 | Tool calling |
| 5 | What was the total revenue at Wuse 2 Abuja in January 2026? | Finds one week's row and calls it the total: ₦682,000 | ₦12,819,000 | Tool calling |
| 6 | Which location sold the most units in March 2026? | Says it has no March sales figures | Victoria Island flagship, 453 units | Tool calling |
| 7 | How much did Ikeja make? | Says it has nothing about anyone called "Ikeja" | Asks which period you mean, or gives the Q1 total (₦45,246,500) and says it covers Q1 | Fine tune prompts, Tool calling |

"Hello" counts as right under both in the eval, because both say hello back.
The difference is the sidebar: normal shows five sources for a greeting, and
optimized shows none.

## Both get these right

These show that normal RAG isn't useless. A plain lookup in the documents
works under both.

| # | Question | Answer |
|---|---|---|
| 8 | How long is paternity leave? | Two weeks, fully paid |
| 9 | Who is the primary contact at Aba Leatherworks? | Mr. Emeka Okafor |
| 10 | As a Stridewell employee, what discount would I get on a pair of Formal shoes that costs 100,000 naira? | 40% off, so you pay ₦60,000 |

## If time is short

The talk is 25 minutes, so you may not get through all ten. These four cover
the most ground:

1. **Hello**: small talk shouldn't pull in documents.
2. **What is the capital of France?**: the model can still answer what it already knows.
3. **What was our total revenue in Q1 2026?**: totals come from code, not from five excerpts.
4. **How much did Ikeja make?**: a vague question gets a question back, not a guess.
