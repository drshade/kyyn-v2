---
id: 0027
title: 'Typed model judgements in KB tools'
status: proposed
date: 2026-09-24
---

# Typed model judgements in KB tools

## Context

[Issue #120](https://github.com/drshade/kyyn-v2/issues/120) introduces a host
capability for narrow model-assisted questions inside authored KB tools. Jev is
the first provider, not the capability's name. The curation agent investigates,
decides what to do and authors an evolution; a judgement model answers a bounded
question within that investigation. It is not the agent or an acceptance authority.

The [TypeSafe HTTP API](https://docs.typesafe.ai/api) accepts state and typed
questions. Its yes/no response is a probability, choice returns an option and
distribution, and scale returns a weighted numeric score and distribution. A
scale's score may lie between levels. These distinctions matter to the authoring
types: do not invent a Boolean decision, rounded level or missing confidence.

## Decision

### Authoring is typed; configuration is explicit

Expose `Judgement` through the existing generated KB-tool request row. An author
uses it by writing a tool that calls it and configuring the provider and local
secret. No per-tool permission flag, registration ceremony or grant registry.
Unused judgement functions cause no provider call or secret lookup. Every tool's
generated row includes the same judgement operations; ordinary types still
separate tools from queries and validators.

The generated `Kyyn.Judgement` module hides injection and wire codecs. Its
`Tool` is the same generated type used by connector proxies, so a single `do`
block can read captured plugin evidence and ask a judgement about it:

```haskell
judge :: Context -> Question answer
      -> Tool (Either JudgementFailure (Judged answer))

newtype Context = Context String

yesNo :: String -> Question YesNoAnswer
choice :: (Bounded a, Enum a, Show a)
       => String -> (a -> String) -> Question (ChoiceAnswer a)
scale :: (Bounded a, Enum a, Show a)
      => String -> (a -> String) -> Question (ScaleAnswer a)
```

`Question` retains the response type. The finite alternatives come from
`[minBound .. maxBound]`; the author provides their descriptions. Choice uses
constructor labels from `Show`; scale uses the enumeration order as its level
order. These are ordinary Haskell types and instances, not a second schema
registry. Reject an empty or duplicate-labelled answer space and provider-unsupported
sizes before sending a request. The first context and instructions are plain
text; the tool composes them with ordinary functions.

```haskell
data Priority = Routine | Important | Urgent
  deriving (Eq, Show, Enum, Bounded)

priorityQuestion :: Question (ChoiceAnswer Priority)
priorityQuestion = choice "Which priority does this message warrant?" description
  where
    description Routine   = "No time pressure or material impact"
    description Important = "Material impact, but no immediate action needed"
    description Urgent    = "Immediate action is required"
```

The result preserves the provider's information and labels distributions with the
author's actual constructors:

```haskell
data YesNoAnswer = YesNoAnswer { probabilityYes :: Double }
data ChoiceAnswer a = ChoiceAnswer
  { selected :: a, probabilities :: [(a, Double)], confidence :: Double }
data ScaleAnswer a = ScaleAnswer
  { score :: Double, probabilities :: [(a, Double)], confidence :: Double }
data Judged a = Judged { provider :: Provider, model :: String, answer :: a }
data Provider = Jev
```

`score` is on the zero-based ordinal scale supplied to the provider, not the
author's numeric `Enum` representation. No implicit threshold, winner selection
for a scale, abstention rule or knowledge mutation. The tool can inspect the
distribution and apply its own policy. Model identity is the response's actual
identity, not a copy of the configured alias.

SDK-owned finite `Double` values serve these approximate model outputs; no new
arithmetic implementation is needed. This does **not** extend the supported
KB/tool input/result contract subset in [ADR 0005](0005-contracts.md). A tool
returning a judgement to an agent currently projects it into that subset, for
example a decision constructor and an explicitly computed integer basis-point
value. Raw `Judged` results containing `Double` are not currently registerable
tool result contracts. Fractional contract support is a separate decision, not
silently introduced through this capability.

### Root configuration and local secrets

One optional `root/judgement.dhall` document selects the provider:

```dhall
{ provider = < Jev >.Jev
, model = "jev-latest"
, secret = "JEV_TOKEN"
}
```

The host owns this small configuration type; provider is a closed union. The
file belongs to the captured code/configuration tree and changes through the
normal evolution workflow. It is not another required `kb.dhall` field. Missing
configuration means judgement is unavailable, not a broken KB. Present but
malformed configuration fails whole-root preparation with a located diagnostic;
checking never probes the model or reads credentials.

Execution uses configuration from the selected root, not a changing ambient
file. The secret name is resolved against that KB checkout's
[local store](0016-connections.md) at invocation time. The provider handler reads
the value and authenticates its own HTTP request. The guest receives neither
the key nor the provider configuration's storage path.

### Host interpretation and the existing continuation

The existing `Program` request/response loop owns suspension and resumption
([ADR 0009](0009-capabilities.md)). Generated code lowers each typed question to
a closed request. It retains the author's constructor mapping in the guest and
decodes the response against that mapping before resuming. No continuation is
serialized; no agent-authored protocol code or extra runtime service is required.

The host has a separate plumbing capability. Its result types contain labels and
level indices, not existential guest Haskell values:

```haskell
data Judgement :: Effect where
  JudgeYesNo :: Context -> YesNoRequest
             -> Judgement m (Either JudgementFailure (Judged YesNoAnswer))
  JudgeChoice :: Context -> ChoiceRequest
              -> Judgement m (Either JudgementFailure (Judged (ChoiceAnswer String)))
  JudgeScale :: Context -> ScaleRequest
             -> Judgement m (Either JudgementFailure (Judged (ScaleAnswer Integer)))

runJudgementIO
  :: (IOE :> es, SecretStore :> es, Failure :> es)
  => Maybe JudgementConfig -> Eff (Judgement : es) a -> Eff es a
```

The provider interpreter uses a maintained native HTTPS client; it is the first
real consumer of SecretStore. Do not add generic guest HTTP or guest secret-access
constructors for this use case. Tool execution depends on `Judgement`, not on
HTTP libraries or `IOE`. A recording interpreter supplies deterministic answers
without credentials or network access.

Each `judge` call makes one provider request containing one question. An authored
tool can compose calls normally. No batch scheduler, persistent response cache,
automatic retry policy or asynchronous job mechanism is needed for this first
journey. A provider refusal returns to the caller, who can decide whether to retry.

The private guest protocol retains [ADR 0007](0007-wire.md)'s numeric-string
profile. Finite doubles travel as round-trippable decimal strings in fixed SDK
codecs; native provider JSON numbers are decoded by the host's maintained JSON
library. Verify host/guest conversion with both compilers rather than relying on
matching pretty-printer spelling. None of these codecs are authored by the KB.

### Expected failure is data, not fabricated judgement

```haskell
data JudgementFailure
  = NotConfigured
  | MissingSecret String
  | InvalidQuestion String
  | AuthenticationRejected
  | RateLimited
  | ProviderUnavailable
  | RequestRejected
  | InvalidProviderResponse
```

Missing setup, invalid questions, authentication/rate-limit refusals, transport
unavailability/timeouts and malformed provider replies are typed outcomes. A
tool may handle them or return its own declared error. Local store access/corruption
remains an operational failure under ADR 0019; it is not `MissingSecret`.
Cancellation propagates, rather than being caught as `ProviderUnavailable`.
Use a finite request timeout and do not automatically retry a potentially billed
call. Never return a default probability or success-shaped empty distribution.

At the provider boundary check the answer kind, exact option/level coverage,
selected option membership, finite numbers, probability/confidence range and
score range. Check distribution totals with a documented floating-point tolerance,
not exact equality or silent normalization. Diagnostics do not echo credentials,
request state, prompts or provider bodies; model calls can contain private evidence.

### Where the capability belongs

The capability is available to KB tools, not snapshot queries, validation,
renderers or plugin captured-read methods. Evolution execution follows
[ADR 0010](0010-evolutions.md#pure-evolution-execution). Root checking compiles
tool code but does not execute it. Tools cannot publish knowledge or accept an
evolution; the investigating agent remains responsible for the resulting proposal.

Do not infer from source text that a tool will or will not call a model. Existing
tool descriptions can explain intended use; there is no per-tool purity claim
or static call-graph discovery feature. Provider licensing and data-use suitability
remain the KB owner's responsibility, not a new runtime approval workflow.

## Consequences and verification

Prove a real MicroHs tool calls the host and resumes with typed Bool-space,
choice and scale results. Compile the same SDK example with GHC, including derived
Enum/Bounded alternatives. Compose a captured-evidence read with judgement in the
same tool. Verify generated interfaces are absent from query/validation contexts.

Recording tests cover success, missing config/secret, invalid question, provider
failure, wrong labels, non-finite/out-of-range values and model-identity forwarding.
Exercise the native HTTPS adapter against a local test server through a test-only
transport configuration; production uses the provider's fixed HTTPS origin.
The installed journey should show an agent-facing tool result and an unchanged
root. Live Jev verification is opt-in with a local key, not an automated suite
requirement; record separately whether a real provider was contacted.
