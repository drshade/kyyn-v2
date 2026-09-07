# 0013 — Users and agents resolve upstream Git conflicts

Status: Proposed. Basis: owner-established separation of local acceptance and upstream work.

## Context

Agents, humans and scheduled jobs may propose against the same root. Git can
merge text that violates cross-record rules or mixes incompatible schema changes.

## Decision

Use ordinary Git to fetch, inspect, merge/rebase and push work. Kyyn does not own
a remote adoption protocol or require a special proposal for every Git conflict
resolution. The user/agent resolves conflicting histories, checks the resulting
KB and pushes it. Kyyn's own proposal acceptance guarantees only ADR 0012's
conditional step from the current local accepted head.

Publish local acceptance as ordinary Git history; normal push rejects a remote
that advanced. Do not use force push as an automatic conflict remedy. A successful
local CAS does not reserve the remote. Report local acceptance and remote
publication separately, allowing review and synchronization after rejection.

An unaccepted evolution can be rebased in place: set `Before.revision` to the new
local head, refresh its schema from that commit, repair the transformation, rerun
it against that commit's facts and inspect the new validation results/diff.
Do not require a new workspace or retained copy of every old attempt. Accepted
workspaces remain historical records. No permanent Stale lifecycle.
ADR 0012 defines the proposed ordinary-branch/draft layout and selective acceptance.
Uncommitted drafts are local; sharing one across machines requires ordinary Git
commit/push or an explicit file transfer. There is no implicit session-sync service.

Initially require an explicit repository and KB path; do not rely on ambient cwd
inside semantic operations. If several KBs share a repository, whole-repository
CAS conservatively conflicts even for unrelated changes. No cross-KB transaction
or branch-per-KB federation is required in the first supported workflow.

## Alternatives and consequences

Git does not determine whether a text-clean merge or deliberate overwrite is
semantically sensible. Types, checks and diffs help; judgment belongs to the
human/agent. Reject a custom distributed coordinator, automated semantic merge,
singleton enforcement and governance of arbitrary working-directory edits.
Raw Git changes remain possible; Kyyn validates unknown roots when loading them
for validated operations, rather than pretending all commits passed through it.
Git transport does not gain authority to call outbound plugins.

## Verification

Two clones can each accept locally against their own heads. After one pushes,
the other's normal push may be rejected; local acceptance remains successful.
Exercise user/agent resolution with ordinary Git, validate the resulting root,
and retry the push. Separately test that two processes sharing one local ref
cannot both accept from the same base. Documentation distinguishes local
acceptance from remote publication without adding an adoption state machine.
