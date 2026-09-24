---
id: 0027
title: 'Typed model judgements in KB tools'
status: implemented
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

### Authoring is typed

Expose `Judgement` through the existing generated KB-tool request row. An author
uses it by writing a tool that calls it and setting the local secret. No per-tool
permission flag, registration ceremony or grant registry.
Unused judgement functions cause no provider call or secret lookup. Every tool's
generated row includes the same judgement operations; ordinary types still
separate tools from queries and validators.

The generated `Kyyn.Judgement` module hides injection and wire codecs. Its
`Tool` is the same generated type used by connector proxies, so a single `do`
block can read captured plugin evidence and ask a judgement about it:

```haskell
ask :: Question answer -> Questions answer
-- Questions has Functor and Applicative instances, but no Monad instance.
judge :: Context -> Questions answer
      -> Tool (Either JudgementFailure answer)

newtype Context = Context String

yesNo :: String -> (Bool -> String) -> Question YesNoAnswer
choice :: (Bounded a, Enum a, Show a)
       => String -> (a -> String) -> Question (ChoiceAnswer a)
scale :: (Bounded a, Enum a, Show a)
      => String -> (a -> String) -> Question (ScaleAnswer a)
```

`Question` retains the response type. `yesNo` requires descriptions for both
`True` and `False`; empty descriptions are refused before sending. They become
the provider's yes/no criteria.

`Questions` composes independent questions applicatively, without sending them.
There is no `Monad` instance: a question in a batch cannot depend on another
answer. `judge` sends the complete batch over one context and assembles the
author's value. A single question uses `judge context (ask question)`. Reject
an empty batch before looking up a secret or calling the provider. Any failure
fails the whole request, with no partially assembled result.

 The finite alternatives come from
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

For example, a tool can assemble an ordinary product type without introducing
a schema registration for it:

```haskell
data Assessment = Assessment (ChoiceAnswer Priority) YesNoAnswer

assessment :: String -> Tool (Either JudgementFailure Assessment)
assessment body = judge (Context body)
  (Assessment <$> ask priorityQuestion
              <*> ask (yesNo "Does this require a reply?" replyDescription))
  where
    replyDescription True  = "The message asks for a response or decision"
    replyDescription False = "The message is informational; no reply is needed"
```

The result preserves the provider's information and labels distributions with the
author's actual constructors:

```haskell
data YesNoAnswer = YesNoAnswer { probabilityYes :: Double }
data ChoiceAnswer a = ChoiceAnswer
  { selected :: a, choiceProbabilities :: [(a, Double)], choiceConfidence :: Double }
data ScaleAnswer a = ScaleAnswer
  { score :: Double, scaleProbabilities :: [(a, Double)], scaleConfidence :: Double }
```

`score` is on the zero-based ordinal scale supplied to the provider, not the
author's numeric `Enum` representation. No implicit threshold, winner selection
for a scale, abstention rule or knowledge mutation. The tool can inspect the
distribution and apply its own policy. Results contain only answers; provider
and model selection are host constants, not part of the guest result.

SDK-owned finite `Double` values serve these approximate model outputs; no new
arithmetic implementation is needed. This does **not** extend the supported
KB/tool input/result contract subset in [ADR 0005](0005-contracts.md). A tool
returning a judgement to an agent currently projects it into that subset, for
example a decision constructor and an explicitly computed integer basis-point
value. Raw judgement results containing `Double` are not currently registerable
tool result contracts.

### One provider interpreter and a local secret

The host interpreter uses the fixed endpoint
`https://api.typesafe.ai/v1/systemone`, the model `jev-1.13.0`, and the secret
name `JEV_TOKEN`. The versioned request identifier is supported by the
[provider's model API](https://docs.typesafe.ai/models). These are host implementation
constants, not a provider registry, configuration document or KB manifest field.

Resolve the key against the explicitly selected KB checkout's
[local store](0016-connections.md) at invocation time. A missing key returns a
typed failure naming `JEV_TOKEN` and the setup command
`kyyn-v2 --kb PATH secret set JEV_TOKEN`. The handler reads the value and
authenticates its own HTTP request; the guest never receives the key. Root
checking compiles tools without reading credentials or probing the provider.

### Host interpretation and the existing continuation

The existing `Program` request/response loop owns suspension and resumption
([ADR 0009](0009-capabilities.md)). Generated code lowers each typed question to
a closed request. It retains the author's constructor mapping in the guest and
decodes the response against that mapping before resuming. No continuation is
serialized; no agent-authored protocol code or extra runtime service is required.

The host has a separate plumbing capability. Its result types contain labels and
level indices, not existential guest Haskell values:

```haskell
data JudgementRequest = JudgementRequest Context [QuestionSpec]
data QuestionSpec
  = YesNoRequest String String String
  | ChoiceRequest String [(String, String)]
  | ScaleRequest String [String]

data JudgementAnswer
  = YesNoResult YesNoAnswer
  | ChoiceResult (ChoiceAnswer String)
  | ScaleResult (ScaleAnswer Integer)

data Judgement :: Effect where
  Judge :: JudgementRequest
        -> Judgement m (Either JudgementFailure [JudgementAnswer])

runJudgementIO
  :: (IOE :> es, SecretStore :> es)
  => Eff (Judgement : es) a -> Eff es a
```

The provider interpreter uses a maintained native HTTPS client; it is the first
real consumer of SecretStore. Do not add generic guest HTTP or guest secret-access
constructors for this use case. Tool execution depends on `Judgement`, not on
HTTP libraries or `IOE`. A recording interpreter supplies deterministic answers
without credentials or network access.

Each `judge` call makes one provider request containing the complete applicative
batch. The host assigns question names `q0`, `q1`, and so on, checks the exact
answer-key set, validates each answer against its question, and returns answers
in request order. The guest's per-question decoders recover the author's types
and assemble the result; missing, extra or mismatched answers cannot produce a
partial value. No scheduler, persistent response cache, automatic retry policy
or asynchronous job mechanism. A provider refusal returns to the caller, who
can decide whether to retry.

The private guest protocol retains [ADR 0007](0007-wire.md)'s numeric-string
profile. Finite doubles travel as round-trippable decimal strings in fixed SDK
codecs; native provider JSON numbers are decoded by the host's maintained JSON
library. Verify host/guest conversion with both compilers rather than relying on
matching pretty-printer spelling. None of these codecs are authored by the KB.

### Expected failure is data, not fabricated judgement

```haskell
data JudgementFailure
  = MissingSecret String
  | InvalidQuestion String
  | AuthenticationRejected
  | RateLimited
  | ProviderUnavailable
  | RequestRejected
  | InvalidProviderResponse
```

Missing secrets, invalid questions, authentication/rate-limit refusals, transport
unavailability/timeouts and malformed provider replies are typed outcomes. A
tool may handle them or return its own declared error. Local store access/corruption
remains an operational failure under ADR 0019; it is not `MissingSecret`.
Cancellation propagates, rather than being caught as `ProviderUnavailable`.
Use a finite request timeout and do not automatically retry a potentially billed
call. Never return a default probability or success-shaped empty distribution.

At the provider boundary check the answer kind, exact option/level coverage,
selected option membership, finite numbers, probability/confidence range and
score range. Check distribution totals with a documented floating-point tolerance,
not exact equality or silent normalization (the tolerance is `1e-3`,
allowing small rounding differences). The [Score answer contract](https://docs.typesafe.ai/api#score-answer)
requires a `legend` mapping level indices to descriptions; check it against the
submitted scale. Diagnostics do not echo credentials,
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
same tool. Verify query/validation types reject judgement calls and `Questions`
does not support monadic composition.

Recording tests cover success, missing secret, invalid question, provider
failure, wrong labels, non-finite/out-of-range values, empty batches, yes/no
criteria, heterogeneous batches and whole-request refusal.
Exercise the native HTTP exchange against a loopback server through a test-only
transport function; production uses the provider's fixed HTTPS origin and the
maintained client's TLS implementation. The loopback fixture does not establish
TLS or verify the live provider's certificate.
The installed journey should show an agent-facing tool result and an unchanged
root. Live Jev verification is opt-in with a local key, not an automated suite
requirement; record separately whether a real provider was contacted.
