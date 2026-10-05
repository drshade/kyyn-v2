# ADR files

[SDLC section 5](../../docs/SDLC.md#5-significant-decisions-are-adrs) owns decision
authority and reconciliation. This page defines the file format; the
[architecture index](../README.md) provides navigation.

Use `NNNN-short-kebab-case-description.md` with a four-digit unique number starting
at 0001. Numbers are never reused, including after deletion; consult Git history
when allocating the next unused number. Concurrent proposals must resolve collisions
before merge. `0000-template.md` is reserved for the template.

Every record uses the template's flat front matter:

- `id`: four digits matching the filename;
- `title`: the H1 without its leading `# `, quoted if needed.

The metadata is intentionally a small format, not arbitrary YAML: one line per
field, exactly these keys, with unquoted scalar values or single-quoted text.
The checker compares the title with the H1 rather than allowing them to drift.
There is no status or date: an ADR owns decided desired architecture, Issues and
PRs own outstanding work, and Git records revisions.

Keep literate prose, concrete signatures, rationale and verification properties
together. The template is not a limit on how precisely a boundary should be
explained. Review establishes whether the record expresses the intended decision;
metadata lint cannot establish architectural correctness.

Run `node tools/checks/check-docs.mjs` to check metadata and local links. Edit
decisions in place; Git and the design PR preserve former wording.
