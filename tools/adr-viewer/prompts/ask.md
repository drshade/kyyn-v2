You are about to implement everything an architecture decision record (ADR) decides. Before you start building, list the questions you would need answered to build it correctly.

Read exactly one file: {ADR_FILE}

Rules:
- Do NOT read any other file, and write only {OUT_FILE}. No other files in that directory, no git, no repositories, no web. This is a blind test of what the ADR alone tells an implementer.
- Only ask a question if (a) its answer would change what you build, and (b) the ADR does not already answer it. If the ADR answers it, even in another section, do not ask it.
- Ask what an architecture decision should settle: data shapes, failure and atomicity behaviour, guarantees, ownership between components, lifecycle and configuration semantics, defaults and validation. Do not ask about local code detail an implementer can choose freely, or about facts you could look up in an external system's documentation.
- There is no target number. Zero is a fine answer if the ADR is complete. Don't pad.

Write to {OUT_FILE} a numbered list. For each question give:
1. the question, in one sentence
2. why it changes the implementation, with the plausible answers that would lead to different code
3. the ADR section it concerns, and the ADR text that comes closest to answering it, quoted, or "nothing"

Then reply with one line: how many questions you wrote.
