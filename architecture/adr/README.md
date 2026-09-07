# ADR files

[SDLC section 5](../../docs/SDLC.md#5-significant-decisions-are-adrs) owns the decision
lifecycle. This page only defines the file format. The [architecture index](../README.md)
provides navigation; the [project practices](../../docs/PROJECT-PRACTICES.md) identify
the pre-adoption baseline.

Use `NNNN-short-kebab-case-description.md` with a four-digit unique number starting
at 0001. Numbers are never reused, including after deletion; consult Git history
when allocating the next unused number. Concurrent proposals must resolve collisions
before merge. `0000-template.md` is reserved for the template.

New records and substantive revisions use that template's flat front matter:

- `id`: four digits matching the filename;
- `title`: the H1 without its leading `# `, quoted if needed;
- `status`: `proposed`, `accepted` or `implemented`, with the SDLC meanings;
- `date`: the decision/revision date as `YYYY-MM-DD`.

The metadata is intentionally a small format, not arbitrary YAML: one line per
field, exactly these keys, with unquoted scalar values or single-quoted text.
The checker compares the title with the H1 rather than allowing them to drift.
Keep the ADR's literate prose, signatures, alternatives and verification discussion;
the short template is not a limit on how precisely a boundary should be explained.

Imported ADRs 0001–0026 may retain their existing numbered H1 and `Status:` line
until substantively revised. The checker validates their naming, ID uniqueness,
heading and presence of that status text, but does not reinterpret its mixed
decision/proposal wording. New numbers require standard front matter. Review, not
metadata lint, establishes the truth of a lifecycle status. Navigation or source-link
repairs alone do not require claiming that a significant decision was revisited.

Run `bash tools/test.sh` to check metadata and local links. Retain only current
guidance in active decision sections; Git and the design PR preserve former wording.
