# Fetch, investigate and curate by recipe

This illustrates the proposed [curation decision](../adr/0014-evidence.md), not
a runnable script. Acquisition, latest-only storage, typed plugin reads and KB
helpers exist; recipes, acknowledgement helpers and pending-work discovery do not
yet. Types/helper names below illustrate the intended author experience.

## 1. Define the tasks and sources

A todo KB has two root-owned recipes:

- `syncTodos`: interpret item/status documents and update todos.
- `groceryPrices`: inspect supermarket prices and update relevant grocery todos.

Their instructions explain the domain work to the agent. They do not define kernel
execution steps. The KB configures a file connector and two supermarket connector
instances; their [configuration and bindings](../adr/0016-connections.md) remain
plugin-owned contracts. A recipe can use all three instances. Another recipe can
process the same evidence without sharing acknowledgements.

## 2. Fetch twice before curating

The file source publishes these acquisition changes:

```text
F1: New milk.txt, New temporary.txt
F2: Updated milk.txt, Removed temporary.txt
```

Only current payloads remain. Asking for pending evidence for `syncTodos`, which
has no prior acknowledgements, returns milk as New at its F2 state. The temporary
item has disappeared without being processed and is not pending. Raw fetch history
still shows both batches; pending work is a different view.

The result carries the file instance and F2 identity as ordinary scope data. Plugin
methods read the latest capture. If another fetch occurs between investigation
calls, the agent may inspect the newer state and select its scope instead; retaining
F2 does not grant historical payload access or prove what the agent has read.

## 3. Handle only selected evidence

The agent reads milk through the plugin's method, then authors an evolution adding
the appropriate todo and explanation. It attaches a declaration such as:

```haskell
withCuration
  (Curation syncTodos [IndividualRecords fileScopeF2 [milkId]])
  todoEdits
```

No fingerprint lookup, register edit or second guest entry point is needed. The
host resolves the declared state while preparing the candidate and shows the
acknowledgement with the fact diff. Acceptance commits facts, the progress update
and the evolution archive together. A rejected candidate acknowledges nothing.

If F3 removes milk after this acceptance, removal is pending for `syncTodos`.
That differs from temporary.txt: milk was acknowledged, even though no whole batch
was handled. The recipe's instructions and agent reasoning determine whether the
corresponding todo should be removed, retained or changed.

## 4. Handle batches across instances

The price recipe can process one supermarket in bulk and a few items from another:

```haskell
withCuration
  (Curation groceryPrices
    [ EntireBatch supermarketAScope
    , IndividualRecords supermarketBScope [milkPriceId, breadPriceId]
    ])
  priceEdits
```

These scopes name independent fetches; there is no global fetch watermark. The
host maintains an acknowledged ID/fingerprint map per recipe and instance. A batch
replaces that map; individual declarations update or remove selected entries.
Declarations apply in authored order. An explicitly older declaration can make
evidence pending again; Kyyn does not enforce monotonic progress.

The evolution may just declare evidence handled with no fact changes when the
agent judges no update necessary. It can also change facts without acknowledging
evidence. Citations explain support; they are not processing receipts.

## 5. Refresh during review

The candidate acknowledges supermarket A at A12. A refresh publishes A13 while
the human reviews it. Acceptance still publishes the fixed A12 acknowledgement,
not A13. Any net differences from A12 remain pending afterward. No historical
payload is retained for this, and acceptance need not access the evidence cache.

The ordinary local-head rule still applies: if another evolution was accepted,
the agent must update the proposal's Before and check it again.

## 6. Empty pending work is not task completion

The user adds another grocery todo, but supermarket evidence has not changed. The
price recipe's pending query returns an empty list. The agent can still read the
current prices and populate the new todo. Kyyn neither blocks the work nor decides
that running the recipe was unnecessary. Acknowledgements are declarations of
processing, not permissions to use evidence.

## 7. Clone or clear the local cache

Clearing the local evidence cache leaves accepted recipes, facts, rationale and
the Git-tracked progress register intact. Another clone has that register too.
After a successful fetch with the same producer, pending discovery compares the
two maps without any previous fetch history. An acknowledged item missing from
the capture is Deleted; acknowledging that deletion removes its register entry.
An unavailable source is an error, not an empty capture.

Producer changes require refetch and explicit reconciliation rather than comparing
incompatible fingerprints. The agent can inspect the new capture and acknowledge
a whole batch under the new producer. This does not reconstruct old payloads.
