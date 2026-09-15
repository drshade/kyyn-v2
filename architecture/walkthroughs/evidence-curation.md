# Fetch, investigate and curate

This is a design walkthrough, not a runnable example or a claim that these commands
already exist. Installation and acquisition are implemented; latest-only storage
is being revised and KB tools remain unimplemented. [Evidence](../adr/0014-evidence.md) owns the retention contract,
[configuration](../adr/0016-connections.md) owns instance bindings, and
[authoring](../adr/0008-authoring.md) owns tool registration. The names below illustrate
those boundaries without fixing generated SDK/module spellings.

## 1. Configure a source

An agent installs a folder plugin and adds an instance to the plugin's root-owned
config. Its Haskell `FolderConfig` contains `directory` and `recursive`; the generated
Dhall union supplies the `Folder` constructor:

```dhall
{ name = "sales-documents"
, binding = "salesDocuments"
, connector = Folder { directory = "/work/sales", recursive = True }
}
```

The generated `Kyyn.Connectors.salesDocuments :: Folder.Instance` is the value KB
code imports. Another configured folder would have its own instance name, binding
and change tracking. Neither requires another plugin installation. The first-party
`local-file` package supplies the folder connector.

## 2. Fetch and inspect

For this example the plugin chooses relative paths as evidence IDs and stores text
contents with their source paths and content fingerprints. The first fetch, F1, returns:

```text
NewEvidence "acme.txt"    { text = "Acme forecast: 100", ... }
NewEvidence "contoso.txt" { text = "Contoso forecast: 200", ... }
```

Kyyn persists the latest values and payload-free markers in ignored Dhall storage and makes F1
the latest captured evidence for this instance. The agent discovers the plugin's
`readDocument` and `summarizeDocument` methods, including their input/result types
and documentation. It calls them against the latest capture, currently F1; Kyyn does not prescribe one generic
view or understand how this plugin extracts useful text.

The agent authors an evolution adding its interpreted sales facts, explanations and
source citations. The KB also chooses to have a `salesCuration` value containing the
last fetch accounted for, initially F1. Accepting that evolution publishes both.
The host does not create this field, mandate its schema or mark evidence reviewed.

## 3. Ask what changed

Later the plugin compares the folder with F1 and returns F2:

```text
UpdatedEvidence "acme.txt"    { text = "Acme forecast: 125", ... }
RemovedEvidence "contoso.txt"
NewEvidence     "fabrikam.txt" { text = "Fabrikam forecast: 75", ... }
```

The host records F2's predecessor F1 and replaces the current evidence. Superseded
Acme text and removed Contoso text are discarded. The agent reads its accepted
curation cursor, requests changes after F1 through the latest fetch, and investigates
those changes with plugin methods.
That change index contains identities, change kinds and citations, not the document
payloads shown in the plugin batch illustration above.
Reading Contoso now returns absent. Its prior meaning is in the KB's accepted facts.
Reading Acme returns 125.

If F3 is fetched during a tool invocation selected at F2, that invocation still
reads its already-loaded input. The next invocation reads F3.

## 4. Compose useful investigation tools

A KB can combine several plugin reads into one agent-sized result. For example,
with separately configured mail and calendar instances:

```haskell
import qualified Kyyn.Connectors as Connectors
import qualified Microsoft.Mail as Mail
import qualified Microsoft.Calendar as Calendar

getActivity day = do
  emails <- Mail.emailsOn Connectors.salesMail day
  meetings <- Calendar.meetingsOn Connectors.teamCalendar day
  pure (Activity emails meetings)
```

`Activity` and `getActivity` belong to the KB. Registering the function exposes its
checked contracts and documentation as a KB tool; registration does not require
handwritten JSON, MCP or IO. Its declared capabilities compose the two captured-read
algebras. The providers could equally belong to different plugins. Their selected
fetches are fixed for this invocation, not necessarily acquired at the same time.
The helper may additionally declare selected-root reads to compare that activity
with accepted facts; ordinary snapshot queries retain their narrower boundary.

Unregistered helpers remain internal functions. Browsing does not fetch new evidence
or invoke a sink; acquisition and output publication are explicit operations.

## 5. Prepare the next evolution

Having investigated F1 → F2, the agent authors the intended changes: adjust Acme's
forecast, remove or retain Contoso according to the KB's policy, add Fabrikam, and
advance `salesCuration` to F2. Source deletion does not itself delete a KB fact.
Each meaningful step carries its rationale and useful evidence citations. The
evolution can contain literal edits chosen by the agent; it need not read those
documents again. A reusable transformation may instead calculate from selected
evidence through the same typed plugin helpers.

The ordinary check produces a candidate and report. A failed check or an abandoned
draft leaves accepted facts and the accepted F1 cursor unchanged. When the agent
marks the proposal ready, the human can inspect the changes and rationale before
accepting facts and the F2 cursor together. The cursor is the KB author's assertion
of progress, not a kernel proof that every document was understood. Another curation
workflow can independently still be at F1.

## 6. Reconcile after cache loss or a plugin change

If the local change markers were cleared, requesting changes since F1 reports
history unavailable. It does not report an empty change list or quietly advance the cursor.
The agent can inspect available current evidence and prepare a reconciliation
evolution. Likewise, after changing the producing plugin, old payloads are not
decoded under the new contract merely because field shapes happen to match.
Refetch using the new plugin and reconcile; old contents are replaced, not archived.

Neither deletion nor a plugin update removes accepted sales facts or their saved
rationales. The citations still identify useful source items when the source now
contains different information or has disappeared.
