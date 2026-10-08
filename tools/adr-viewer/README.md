# adr-viewer

A replayable plan-versus-build history of this repository's ADRs. Each ADR is a
**lane**; the decisions it has carried are **nodes** on that lane. A node is white
while the spec asks for something the code does not yet do and green once the code
realises it. When the spec evolves, that is a new node that supersedes the old one,
so history is never painted over. The rendered page lets you drag through time
and watch the plan and the build converge.

This README is the complete guide for an agent asked to update or render the
history. Everything the tool needs lives in this directory; nothing under
`architecture/` is read except through git history, and nothing outside this
directory is written.

## Three stages

```
          mechanical                judgement                   mechanical
git + GitHub ──extract──▶ evidence/ ──curate (agent)──▶ curated/ ──render──▶ history.html
```

| Stage | Who | Reads | Writes |
| --- | --- | --- | --- |
| `extract` | the tool | first-parent git history, merged PRs via `gh` | `evidence/` only |
| curate | an agent, following this README | `evidence/` (including worklists) | `curated/lanes/<ADR>.json` only |
| `check` | the tool | `evidence/`, `curated/` | nothing; prints diagnostics |
| `render` | the tool | `evidence/`, `curated/` | one HTML file |

```
tools/adr-viewer/
├── evidence/                 written only by `extract`
│   ├── steps.json            committed: one entry per first-parent step
│   ├── adrs.json             committed: ADR ids, titles, born/deleted steps
│   ├── repo.json             committed: repository name and URL
│   └── worklists/            ignored: the curator's reading material
│       ├── <ADR>.jsonl       every step that changed that ADR, with its diff
│       ├── anchors.json      every anchor's spec/code history
│       └── steps.jsonl       every step with PR body and changed code files
└── curated/                  written only by the curating agent
    └── lanes/<ADR>.json      decisions for one ADR, current through its cursor
```

Never edit `evidence/` by hand; rerun `extract`. Never let the tool write
`curated/`; it is reviewed judgement, and its git diff is the review.

## Commands

Run from this directory. The tool has its own `cabal.project` and is not part of
the root build. `extract` needs an authenticated `gh` for PR titles and bodies.

```sh
cabal run -v0 adr-viewer -- extract --repo ../.. --output evidence
cabal run -v0 adr-viewer -- check                      # defaults: --evidence evidence --curated curated
cabal run -v0 adr-viewer -- render --output /tmp/adr-history.html
cabal test                                             # model, checks and ADR readings
```

`extract` is deterministic: rerunning it on the same history leaves the committed
evidence files unchanged. `render` runs every `check` first and refuses data with
errors; warnings are printed but do not block. Open the HTML file directly in a
browser. It is self-contained and is not committed.

## Concepts

- **Step**: one first-parent commit on `main`, numbered `seq` from 0. Almost
  every step is a merged PR. Seq numbers are stable because history only grows.
- **Anchor**: an identifier an ADR names in backticks or fenced code, such as a
  CamelCase type or a function signature. `extract` records when each anchor
  enters or leaves an ADR, and when it appears in or disappears from code.
  Anchors are evidence for realisation, not proof: a type existing is not a
  feature working.
- **Lane**: one ADR's history of decisions, in `curated/lanes/<ADR>.json`.
- **Cursor**: the last global step seq a lane has been curated through. The
  last step in `evidence/steps.json` is the target, not the last step that
  touched the ADR. Steps that change only code still matter, because they can
  realise open decisions.

## Curating: the update loop

When asked to bring the history up to date:

1. Run `extract`. Note the last seq in `evidence/steps.json`.
2. Run `check`. Lanes reported as "N steps behind" are your work list. A lane
   file is missing for an ADR that has never been curated; create it, starting
   at the ADR's founding step.
3. For each behind lane, work through the steps after its cursor, in order:
   - Steps that changed this ADR are in `evidence/worklists/<ADR>.jsonl` (each
     entry has `diff`, `body`, `code_files`, `spec_added`, `spec_removed`,
     `code_added`). Apply the rules below to each one.
   - For every step after the cursor, including code-only steps, check whether it
     realises a live node that is still `unrealised`. Use `code_added` in
     `evidence/worklists/anchors.json` and the PR bodies in
     `evidence/worklists/steps.jsonl` (grep by seq or PR number; the file is
     large). If it does, set that node's `realised` to `later_step` with the
     step's seq. Never change a node's history otherwise: earlier nodes keep
     their meaning, and new understanding becomes new nodes.
   - Set `cursor` to the last seq.
4. Run `check` until it reports no errors, and read the warnings.
5. `render` and open the page if asked to show the result.

Do one lane at a time and keep each lane's edit self-contained, so the diff of
each `curated/lanes/<ADR>.json` reads as that lane's update. You may read
`../../` source to judge realisation; do not modify anything outside this
directory.

## Curation rules

For each step that changed the ADR:

1. **Editorial or decision?** Rewording, link fixes, tightening prose, or
   bringing the text in line with code that already matches it, without changing
   what the architecture requires, is editorial. Record it in `editorial` and
   create no node.
2. **Which decisions does it carry?** One step can make several decisions, and
   one decision can span several sections. Create one node per decision.
3. **How does it relate to existing nodes?**
   - `new`: a commitment the lane did not previously make. `supersedes` is empty.
   - `refine`: extends or sharpens an existing decision without contradicting
     it, such as adding a field, a rule or a failure case. List it in
     `supersedes`. The old node stops being live; its decision continues in the
     refinement.
   - `replace`: the earlier decision is no longer the architecture. List it in
     `supersedes` and set the old node's `ended` to
     `{ "seq": <this step>, "how": "replaced", "by": "<new id>" }`.
   - Deleted with no replacement: set the old node's `ended` with
     `"how": "removed"`. Put the step in `editorial` if it creates no node.
4. **Is it realised, and when?**
   - `same_step`: the step that wrote it also implemented it (the PR changed
     relevant code and its body says so). `seq` is the node's own seq.
   - `later_step`: implemented by a later step. Give that step's `seq`.
   - `code_first`: the code already did it before the spec said so, so the ADR
     caught up. Give the `seq` where the code appeared.
   - `unrealised`: no evidence the code does it yet. `seq` is null.
   - `unknown`: cannot tell. `seq` is null.

   Prefer explicit PR bodies over anchor presence.

Consistency rules (other lanes are curated separately, so apply these exactly):

- **Founding granularity:** the founding step is the ADR's first version.
  Create one node per `###` subsection of the Decision section, or per distinct
  commitment if it has none. Typically that gives 4–12 nodes. Merge subsections
  that only elaborate a sibling. Split one only when it makes clearly
  independent commitments. Context, Consequences, Alternatives and Verification
  sections produce no nodes.
- **Reconciliation steps** (repo-wide rewrites such as seq 143, "reconcile
  ADRs as desired-state architecture", and metadata cleanups): a change that
  rewords something an existing node covers is editorial. A change that states a
  commitment no node covers yet, which the code already did, is a `new` node
  realised `code_first`. A reversal is a `replace`.
- **Version or format bumps** are a `refine` only when they change what the
  architecture requires; otherwise they are editorial.
- **Negative constraints** ("there is no X", "never Y") are `same_step` if the
  code at that time conforms, otherwise `unknown`.

## Lane file format

```json
{
  "adr": "0014",
  "title": "Current evidence and recipe-owned state",
  "cursor": 166,
  "nodes": [
    {
      "id": "0014.01",
      "seq": 1,
      "pr": null,
      "summary": "<= 12 words: the decision itself",
      "detail": "1-3 sentences: what the architecture requires and why it matters",
      "kind": "new",
      "supersedes": [],
      "sections": ["Decision / One current captured value per evidence item"],
      "anchors": ["EvidenceRef"],
      "realised": { "how": "later_step", "seq": 78, "evidence": "short reason" },
      "ended": { "seq": 84, "how": "replaced", "by": "0014.12" },
      "confidence": "high"
    }
  ],
  "editorial": [ { "seq": 78, "pr": 96, "note": "why it is editorial" } ],
  "notes": "How the lane evolved: detours, reversals, where the spec ran ahead of or behind the code, and splitting choices a reviewer should check."
}
```

| Field | Values |
| --- | --- |
| `kind` | `new`, `refine`, `replace` |
| `realised.how` | `same_step`, `later_step`, `code_first`, `unrealised`, `unknown` |
| `ended.how` | `replaced`, `removed` |
| `confidence` | `high`, `medium`, `low` |

Ids are `<ADR>.<two-digit counter>` in creation order, and existing ids never
change. Omit `ended` while a decision is current. `pr` is the step's PR number,
or null for a direct commit. Keep `notes` current: it is shown when a reader
clicks the lane.

## What `check` enforces

Errors (render refuses):

- the file name matches `adr`, and the ADR exists in `evidence/adrs.json`
- the cursor is not beyond the last step
- ids are unique and well formed
- every `supersedes` and `ended.by` names a node in the lane, and `supersedes`
  never points to a later node
- `new` supersedes nothing, and `refine`/`replace` supersede something
- `later_step` and `code_first` give a `realised.seq`
- nothing ends before it is born, and no node or editorial seq is beyond the cursor
- **coverage:** every step up to the cursor that changed the ADR is a node's
  `seq` or an editorial entry

Warnings:

- a lane is behind the evidence
- a node's seq is not a step that changed its ADR
- a realisation is dated inconsistently with its `how`
- a replacement is not named

## How the page is derived

`render` computes everything the page shows in Haskell (`src/AdrViewer/Model.hs`).
The browser only compares those values with the step being shown, and draws.

- A node is **live** from its `seq` until the earliest of its `ended.seq` and
  the seq of any node that supersedes it.
- It counts as **realised** from `same_step` (its own seq) or `later_step` and
  `code_first` (`max(seq, realised.seq)`), but only if that happens while it is
  live. A node never turns back from realised to specified.
- **Tracks:** a successor takes its predecessor's row when that predecessor has
  just stopped being live. Otherwise it takes the free row nearest its
  predecessor. Rows never overlap in time.
- **Lane counts** per step are live decisions realised and live decisions still
  ahead of the code. **Convergence** is the realised share across all lanes.

Reading the page: drag along the timeline band at the top (the convergence
chart and the date axis), press ▶ to replay, or use ← and →. Each lane starts
collapsed as a summary bar. Click its label to expand it into decision tracks
and read its `notes`, or use **Expand all**. Faded green means delivered and
then superseded. Faded white means superseded before it was built.

## Limits

- Curation is judgement. Lanes record their uncertain calls in `notes` and in
  `confidence`; review lane diffs as you would any design change.
- Anchors miss prose-only decisions. Realisation for those rests on PR bodies
  and reading the code.
- Binary files are skipped when matching anchors in code.
- The data format is JSON for now. A later move into a Kyyn KB (a git-history
  source plugin, lanes as typed facts, curation as a recipe and the page as an
  output) is the intended direction, not part of this tool.
