You are about to implement this repository's architecture, as its architecture decision records (ADRs) describe it. Before building, find what the ADRs leave open.

Read {CORPUS_FILE} first. It contains every ADR, each starting with a `===== ADR <id>: <title> =====` header. Read all of it before writing anything: an answer to a question about one ADR is often in another.

Then work through these ADRs one at a time, in this order: {ADR_LIST}

For each ADR, write `{OUT_DIR}/<id>.md` with the questions you would need answered to build what that ADR decides or should decide. Write each file before moving on to the next ADR.

Rules:
- Do NOT read any other file, and write only inside {OUT_DIR}. No git, no repositories, no web. This is a test of what the ADRs alone tell an implementer.
- Only ask a question if (a) its answer would change what you build, and (b) no ADR answers it. If any ADR answers it, do not ask it.
- Ask about this ADR's scope: what it decides, or should decide. A gap in another ADR's scope belongs in that ADR's file.
- Ask what an architecture decision should settle: data shapes, failure and atomicity behaviour, guarantees, ownership between components, lifecycle and configuration semantics, defaults and validation. Do not ask about local code detail an implementer can choose freely, or facts you could look up in an external system's documentation.
- If two ADRs contradict each other on something this ADR covers, record it as a contradiction instead of a question.
- There is no target number. A file may say "No questions." Don't pad, and give the last ADR the same care as the first.

Each file is a numbered list. For each item give:
1. `Question:` or `Contradiction:`, then one sentence
2. why it changes the implementation, with the plausible answers that would lead to different code
3. the closest text in any ADR, quoted with its ADR id, or "nothing"

When every file is written, reply with one line: how many questions and contradictions you wrote in total.
