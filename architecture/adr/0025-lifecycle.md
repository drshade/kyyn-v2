# 0025 — Agent-driven setup and per-KB execution

Status: Proposed. Basis: owner direction on simple per-KB operation, regular-user
accessibility, agent-driven installation and headless automation.

## Context

Installation, choosing a KB, launching its interfaces and stopping work form one
product journey. They cannot be left implicit between the distribution and UI
decisions. Making them easy does not require a global daemon or a graphical
installer before the product is useful.

## Decision proposed

An agent can bootstrap/install Kyyn, check readiness, locate or create a KB, and
launch its Web interface for the human. Explain what was installed and any action
still needed. ADR 0020 defines the platform and dependency requirements.
CLI navigation and KB selection are owned by
[ADR 0018](0018-surfaces.md#cli-navigation-and-kb-selection). Examples below
illustrate the lifecycle, not commands already available in the prototype.

Local secret setup targets the explicitly selected KB checkout's store under ADR 0016.
An agent can help populate its required keys before invoking sources or sinks;
secret values are not copied through Git or resolved from another KB's settings.
Setup must remain usable from the CLI without starting Web or an MCP server.

On day two the agent, or a CLI-comfortable human, starts the Web server on demand
again. Leaving it running is an explicit process choice, not required KB state.
A persistent launcher is a possible later convenience, not a missing prerequisite
that the first implementation must silently invent.

Use per-KB processes with explicit repository/KB selection:

- A Web command starts the local server for one KB, reports its address and can
  open that address in the human's browser. The server process is explicit; a
  browser tab closing does not itself stop it.
- An MCP command serves one KB, initially through stdio launched by the agent's
  client. Provide an accurate invocation/configuration example the installing
  agent can use. No manual configuration expertise is required of the human;
  automatic registration for every client is not a prerequisite.
- Ordinary CLI operations execute directly and exit, with structured results and
  useful exit codes. They require neither a Web server nor an MCP connection.

Web and MCP may be separate processes using the same repo and local caches. They
share persisted KB/workspace state, not a privileged in-memory owner. Opening a
KB means selecting it and making an interface available, not creating a canonical
interactive-session object. It does not inject that KB's tools into every other
agent session. Multiple instances are allowed; ADR 0012 supplies the local-head
acceptance rule. No global KB registry or session broker is required.
This does not forbid a process from holding an immutable `Validated Root` across
requests under ADR 0011; that value is a selected snapshot, not ownership of the KB
or an assertion that it remains current head.

Startup inspects identity/metadata without eagerly checking every root or compiling
every plugin. A first operation that needs executable KB code may compile on a
fresh clone; report that progress and any failure. Other cheap operations such as
listing drafts must remain usable independently. Shared compiled-artifact caches
publish complete entries as described in ADR 0006. Clients refresh persisted
workspace/results to observe each other's work; collaborative editing or
cross-process cancellation is not part of the initial contract.

Closing means stopping the relevant server/connection or allowing a one-shot
command to finish. Keep drafts as files; closing neither accepts nor deletes them.
Cancel owned in-flight work and release resources under ADRs 0007 and 0019.
Checks without saved results can be rerun. Once acceptance or external dispatch
has occurred, report its actual outcome rather than promising shutdown rolled it
back. Stopping Web need not stop a separate MCP process or vice versa.

## First useful journey

Use ADR 0021's synthetic reporting KB. The human asks an agent to install Kyyn
and open the KB. Web shows a selected report, assumptions and supporting records.
The agent discovers the model/tools through MCP. They evolve a policy and schema,
review the changed report and examples, accept locally and reopen the same result.
Drafts can be left unfinished and resumed without a long-lived service.
This complete product journey spans implementation slices 3–4 in ADR 0021:
preview/check first, then the coherent acceptance boundary including its race,
deletion and failure behavior. It is not a claim that slice 3 alone can accept.

## Automation is ordinary CLI scripting

The initial automation requirement is a scriptable CLI, not a Kyyn runner or agent
orchestrator. An external shell script creates an evolution workspace, invokes
the user's chosen agent harness to populate/trial/refine it and mark it Ready,
then asks Kyyn to accept it and update a declared output. The script is illustrative;
the helper and argument-file convention are not additional Kyyn interfaces:

```sh
set -e
kyyn evolution new monthly-import
# ...extract the returned workspace ID into evolution_id...
./prepare-with-agent "$evolution_id"
kyyn evolution accept "$evolution_id"
kyyn output publish monthly-report --args report-arguments.json
```

`prepare-with-agent` stands for the user's own script calling an agent, not a
Kyyn command, installed helper or harness integration. The agent uses the same
workspace/evaluation/checking operations as interactive work. Output arguments
are ordinary typed renderer inputs; they are not a separate evolution invocation
manifest. The last command composes ADR 0017's preparation and explicit sink
invocation, with no required interactive preview or confirmation.

Acceptance requires Ready as well as a checked current candidate and the local
Before-revision match (ADR 0012). If the agent cannot complete the work, it can
leave the workspace unready. Even if the agent process exits successfully, the
accept command then fails with a non-zero exit and a useful diagnostic. Keep the
workspace and available results for inspection/refinement; do not mark it Ready,
accept a partial result, or delete it to make the script succeed. Acceptance does
not secretly rerun an evolution that lacks a prepared result. Fresh validation
may check the saved result, but must not repeat its external acquisition.

With normal stop-on-error scripting, a failed acceptance prevents the output
command from running. Kyyn supplies reliable results/exit codes, not ownership of
the surrounding script. Base conflicts, failed checks and uncertain sink outcomes
are surfaced honestly. No built-in scheduling, retries, task inbox, agent launching
or workflow state machine is required. The same commands work without Web/MCP
servers. The reporting slices prove the local creation/check/accept/output path;
source acquisition extends it through the usual plugin capabilities.

## Alternatives and verification

Reject a hidden daemon prerequisite, global session management, mandatory GUI
installation and an MCP-only application core. Per-KB launching still needs a
tested client invocation, endpoint discovery, local Web binding/origin handling
and shutdown behavior. ADR 0018 owns the transport boundary, not the domain stores.

On Linux, macOS and Windows via WSL, test bootstrap/readiness, agent-managed MCP
connection, human browser access, stop/reopen and CLI execution without either
server. Exercise port conflicts, missing tools, first-use compilation and an
interrupted operation with an unfinished draft. Windows tests must cover the host
browser and MCP client reaching/launching the WSL process with correct paths.
Document supported configurations and actionable failures; do not assume platform
forwarding or client launch behavior without testing it.

For unattended use, run the repeatable workflow against a disposable KB with
explicit acceptance intent, then test changed-head and failed-check cases. Include
an agent harness that exits successfully but leaves the evolution Draft: acceptance
must fail, retain the workspace for review and prevent a stop-on-error script from
invoking the output sink. Also exercise a Ready, checked evolution through acceptance
and the renderer-to-sink command with no server or human prompt. Include
the ordinary-user setup story in ADR 0024's fresh-agent field experiments. A clean
developer shell alone is not evidence of successful installation or human usability.
