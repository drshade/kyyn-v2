{RUNS} independent agents each read an architecture decision record (ADR) and listed the questions they would need answered before implementing it. Merge and judge their questions, and write the result as a JSON file.

Read only these files:
- {ADR_FILE}: the ADR.
- {RUN_FILES}: the question lists, one per agent.
- {DECISIONS_FILE}: the ADR's current decisions, one per line: id, summary, [sections].
Do not read anything else (no git, no repositories, no web).

Steps:
1. **Merge.** Group questions that ask the same thing, even if worded differently. Keep two questions separate if their answers could differ independently. Record how many of the {RUNS} lists asked each merged question (count a list once even if it asked it twice).
2. **Check against the ADR.** Drop any merged question the ADR already answers anywhere: stated, or following necessarily. Otherwise its verdict is `partly_answered` (the ADR covers part of it) or `unanswered`. Be strict: a reasonable default is not an answer.
3. **Rate importance** on this fixed scale, by what a wrong guess would cost, not by topic:
   - `high`: a wrong guess is expensive to undo or breaks a guarantee: data compatibility or migration, failure and atomicity behaviour, security or secret boundaries, ownership between components, or what the deliverable is.
   - `medium`: a visible contract choice that can change later with a migration or a small break: representations, output or error shapes, configuration validation.
   - `low`: an edge case or default with an obvious reasonable choice that is cheap to change.
4. **Map to decisions.** List the ids from {DECISIONS_FILE} that each question is about, or none.
5. **Summarise** in one short sentence how close the ADR is to implementable as written, naming its biggest gap.

Write {OUT_FILE} as JSON with exactly this shape, questions sorted by count (descending) then importance (high first):

```json
{
  "adr": "{ADR}",
  "step": {STEP},
  "date": "{DATE}",
  "runs": {RUNS},
  "summary": "…",
  "questions": [
    {
      "text": "the merged question, one short sentence",
      "asked": 5,
      "verdict": "unanswered",
      "importance": "high",
      "reason": "one line: why it matters, and what the ADR says closest to it",
      "nodes": ["{ADR}.01"]
    }
  ]
}
```

Omit `nodes` when a question maps to no decision. Write only that file, then reply with one line: the number of merged questions and how many of them were raised by at least {RECURRING} lists.
