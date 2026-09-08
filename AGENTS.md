# Working on Kyyn

Read [the SDLC](docs/SDLC.md) and [project practices](docs/PROJECT-PRACTICES.md)
before working here. They own development process; do not duplicate those rules
in agent instructions. The adoption is prospective, not a rewrite of past work.

For design, start with [architectural principles](architecture/principles.md),
[the architecture index](architecture/README.md), and the owning ADRs. The
[repository layout](architecture/adr/0026-repository-layout.md) is a destination,
not a request to generate empty packages. Historical experiments are evidence,
not implementation to copy by default.

The default verification entry point is `bash tools/test.sh`. Its current scope
and prerequisites are recorded in project practices. Use the repository's PR and
Issue templates where applicable; transient execution details belong in the session.
