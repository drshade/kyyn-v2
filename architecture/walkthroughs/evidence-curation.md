# Fetch, investigate and curate

This is a design walkthrough, not a runnable example or a claim that these commands
already exist. Installation is implemented; source invocation, fetch storage and
KB tools are not. [Evidence](../adr/0014-evidence.md) owns the history contract,
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
and history. Neither requires another plugin installation. The installation fixture
currently called `local-file` is not yet this folder connector.

## 2. Fetch and inspect

For this example the plugin chooses relative paths as evidence IDs and stores text
contents with their source paths. The first fetch, F1, returns:

```text
NewEvidence "acme.txt"    { text = "Acme forecast: 100", ... }
NewEvidence "contoso.txt" { text = "Contoso forecast: 200", ... }
```

Kyyn persists the complete successful batch in ignored Dhall storage and makes F1
the latest captured evidence for this instance. The agent discovers the plugin's
`readDocument` and `summarizeDocument` methods, including their input/result types
and documentation. It calls them against F1; Kyyn does not prescribe one generic
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

The host records F2's predecessor F1 and materializes its resulting snapshot. F1's
payloads remain available. The agent reads its accepted curation cursor, requests
changes after F1 through F2, and investigates those changes with plugin methods.
That change index contains identities, change kinds and citations, not the document
payloads shown in the plugin batch illustration above.
To understand the removed Contoso document it reads that ID at F1; at F2 it is
absent. Reading Acme at F1 returns 100, not F2's 125.

If F3 is fetched during a tool invocation selected at F2, that invocation still
reads F2. Across separate agent calls, explicitly selecting F2 keeps the investigation
on that fetch; a new default-current invocation may select F3. This distinction
does not need a persistent agent session or a global lock on fetching.
The caller supplies the historical choice as a per-instance invocation parameter;
the generated connector binding and ordinary helper source do not change.

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

## 6. Handle missing or incompatible history honestly

If someone explicitly deletes needed F1 history, requesting F1 → F2 reports history
unavailable. It does not report an empty change list or quietly advance the cursor.
Deleting history alone preserves the materialized current evidence; clearing the
entire evidence store is a separate, explicit scope of deletion.
The agent can inspect available current evidence and prepare a reconciliation
evolution. Likewise, after changing the producing plugin, old payloads are not
decoded under the new contract merely because field shapes happen to match.
Refetch using the new plugin and reconcile; no automatic evidence migration.

Neither deletion nor a plugin update removes accepted sales facts or their saved
rationales. The citations still identify useful source items, even when historical
local payloads are unavailable or the source now contains different information.
