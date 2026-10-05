---
id: 0027
title: 'Agentic judgements backed by Jev'
---

# Agentic judgements backed by Jev

## Context

[Issue #169](https://github.com/drshade/kyyn-v2/issues/169) replaces Kyyn's
separate judgement authoring API with haskell-agentic's SystemOne interface.
Tools already execute Agentic workflows, as do closed recipes. A judgement-only
workflow is an ordinary workflow, not a second kind of tool.

The owner explicitly chose upstream's types and semantics over compatibility
with Kyyn's original API. Evolve genuine deficiencies upstream rather than
maintain a parallel question vocabulary or compatibility facade.

## Decision

### One authoring interface

Authors use `Agentic.judge` and `Agentic.Questions`. Independent questions compose
applicatively; the result can feed later flow steps, including drafting, plugin
reads and fact proposals. A tool can expose a judgement-only flow to an open agent.

```haskell
-- Library types, not definitions copied into Kyyn.
judge :: (Contract input, Typeable input)
      => Questions answer -> Agentic m input answer
yesNo :: Text -> Questions YesNo
choice :: Options a => Text -> Questions (Choice a)
score :: Options a => Text -> Questions (Score a)

-- Generated Kyyn integration, shared with SystemTwo.
type Flow input output = Agentic (ExceptT FetchError Tool) input output
interpret :: Flow input output -> input -> Tool (Either FetchError output)
```

Agentic owns the author-facing question/answer types, probability, choice and score
semantics, including its basis-point probability representation and weighted
`Double` score.

Agentic values are internal workflow values. This does not expand the public
KB schema subset: a registered tool's output still needs a supported declared
contract. Authors project a judgement into their chosen result (for example
a Boolean policy decision or integer basis points) where necessary. Generating
more public schema support is a separate decision, not a second judgement API.

### The host supplies SystemOne

The generated Agentic runtime connects `SystemOne` to an existing typed guest
request. Both sides use upstream types directly:

```haskell
data Judgement :: Effect where
  Judge :: Agentic.JudgeRequest
        -> Judgement m (Either ModelFailure [Agentic.Answer])
```

`Judgement` here is host plumbing, not another SDK authoring surface. Tools and
closed recipes use the same broker. Queries, validators and pure evolution
transforms do not acquire model capabilities. Root checking compiles authored
flows without executing them or reading secrets.

Use the native upstream `agentic-jev` provider through `ProvidesSystemOne`, just
as SystemTwo uses the upstream OpenAI and Anthropic adapters. Kyyn does not own
another Jev request builder or answer model. Provider fixes belong upstream.

Resolve `JEV_TOKEN` from the selected KB's checkout-local SecretStore, then pass
it explicitly to the adapter. Missing or empty keys refuse before constructing
the provider; never fall back to environment credentials. Jev requests use model
`jev-1.13.0`. No new configuration registry or
usage limits. The guest never receives the credential.

Translate provider/HTTP exceptions into sanitized host failures, following the
SystemTwo pattern. Do not expose provider bodies, prompts or keys in diagnostics.
Cancellation propagates. Failure terminates the flow through its existing error
channel; no fabricated answers or partial successful batch.

### Wire encoding is plumbing, not a domain shim

Encode upstream `JudgeRequest` and `[Answer]` using the existing continuation
protocol. The guest's Agentic interpreter retains typed question assembly;
the host executes one SystemOne request and returns its answers. No serialized
continuation or new service is needed.

Reuse the internal Agentic value codec used by SystemTwo for request state.
Probabilities and indices use numeric strings; finite scores use decimal strings
round-tripped to `Double`. These internal library values do not change persisted
fact formats or the public schema vocabulary. Both compilers must agree on the
codec. Neither KB authors nor plugin authors implement it.

## Verification

Record native SystemOne requests to prove explicit local credentials, missing and
empty credential refusal, sanitized provider failure and cancellation propagation.
Exercise upstream request/answer mapping without calling the live provider.

Compile and execute a judgement workflow with GHC and MicroHs through actual
guest frames. Cover mixed yes/no, choice and score questions, typed answer
assembly, failure and malformed replies. Execute it through ordinary tools and
closed-recipe preparation, proving they share the broker and produce ordinary
outputs/proposals. Check generated API discovery no longer advertises the old
public modules. Live Jev verification is a separate opt-in.
