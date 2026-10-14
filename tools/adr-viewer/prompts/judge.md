{RUNS} independent agents each read every architecture decision record (ADR) and listed, per ADR, the questions they would need answered to implement it, plus any contradictions between ADRs. Merge and judge their lists, one ADR at a time, and write one JSON file per ADR.

Read {CORPUS_FILE} first: every ADR, each starting with a `===== ADR <id>: <title> =====` header.
Then work through these ADRs in order: {ADR_LIST}
For each ADR `<id>`, read only:
- {RUN_DIRS}: in each, `<id>.md` is one agent's list for that ADR.
- `{DECISIONS_DIR}/<id>.txt`: the ADR's current decisions, one per line: id, summary, [sections].
Do not read anything else (no git, no repositories, no web).

For each ADR:
1. **Merge.** Group items that ask the same thing, even if worded differently. Keep two items separate if their answers could differ independently. Record how many of the {RUNS} lists raised each merged item (count a list once).
2. **Check against all ADRs.** Drop any question that any ADR answers: stated, or following necessarily. Otherwise its verdict is `partly_answered` (some ADR covers part of it) or `unanswered`. Be strict: a reasonable default is not an answer. Keep a contradiction only if the quoted texts really conflict.
3. **Rate importance** on this fixed scale, by what a wrong guess would cost, not by topic:
   - `high`: a wrong guess is expensive to undo or breaks a guarantee: data compatibility or migration, failure and atomicity behaviour, security or secret boundaries, ownership between components, or what the deliverable is.
   - `medium`: a visible contract choice that can change later with a migration or a small break: representations, output or error shapes, configuration validation.
   - `low`: an edge case or default with an obvious reasonable choice that is cheap to change.
4. **Map to decisions.** List the ids from the decisions file that each item is about, or none.
5. **Summarise** in one short sentence how close the ADR is to implementable, naming its biggest gap.

Write `{OUT_DIR}/<id>.json` with exactly this shape, items sorted by count (descending) then importance (high first):

```json
{
  "adr": "<id>",
  "step": {STEP},
  "date": "{DATE}",
  "runs": {RUNS},
  "summary": "…",
  "questions": [
    {
      "kind": "gap",
      "text": "the merged question, one short sentence",
      "asked": 3,
      "verdict": "unanswered",
      "importance": "high",
      "reason": "one line: why it matters, and the closest text in any ADR (with its id)",
      "nodes": ["<id>.01"]
    }
  ]
}
```

`kind` is `gap` or `contradiction`; for a contradiction, the text names both ADRs and the verdict is `unanswered`. Omit `nodes` when an item maps to no decision. Write each file before moving on to the next ADR, and give the last ADR the same care as the first. When done, reply with one line per ADR: its id, merged items, and how many were raised by at least {RECURRING} lists.
