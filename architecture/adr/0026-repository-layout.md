---
id: 0026
title: 'One repository, explicit package boundaries'
---
# One repository, explicit package boundaries

## Context

The kernel, guest SDK, compiler integration and first-party plugins will evolve
together. Splitting them across repositories would introduce coordinated changes
and releases before they have independent development needs. A single repository
must not erase their architectural boundaries or give first-party plugins privileged
access to the host implementation.

## Decision

Develop Kyyn in one repository with separate packages for dependency boundaries.
The host/guest split is an execution boundary; the host's porcelain/plumbing split
is an architectural dependency boundary. They are not interchangeable layers.

The intended layout is:

```text
kyyn-v2/
├── README.md
├── flake.nix                         Host package, guest SDK, KB helper and dev shell
├── flake.lock                        Pinned external inputs
├── cabal.project
├── architecture/                      ADRs, principles and field templates
│
├── shared/
│   └── kyyn-types/                    Pure vocabulary shared by host and guest
│
├── host/
│   ├── kyyn-domain/                   Pure host entities and result types
│   ├── kyyn-porcelain/                Semantic capabilities and application operations
│   ├── kyyn-porcelain-interpreters/   Interpret porcelain through other capabilities
│   ├── kyyn-plumbing/                 Plumbing capability definitions
│   ├── kyyn-plumbing-interpreters/    Interpret plumbing through native IO
│   ├── kyyn-surfaces/                 CLI, MCP and HTTP adapters
│   └── kyyn/                          Executable entry point and execution composition
│
├── guest/
│   ├── kyyn-sdk/                      Public API for KB and plugin authors
│   ├── kyyn-runtime/                  Private guest transport and execution support
│   └── kyyn-guest-build/              GHC inspection, bindings and Nix build helper
│
├── plugins/
│   ├── files/                         First-party file sink
│   └── microsoft-graph/               One plugin, multiple connector types
│
├── examples/
│   └── todos/                         KB template instantiated into its own repository
│
├── tests/
│   ├── integration/                   Cross-package and real Git/runtime tests
│   └── field-scenarios/               Prepared KBs, agent tasks and expectations
│
└── tools/                            Bootstrap, packaging and development scripts
```

This is a destination layout, not a scaffolding checklist. Create each directory
and package only when the current implementation has work for it. The named plugins
and todo KB illustrate placement, not existing implementations or a requirement
to build them all in the first slice. Real user KBs remain separate repositories.

Each implemented Haskell package has its own Cabal file, `src/` and package-local
`test/` where needed. The repository flake exports `packages.${system}.kyyn`
(also its default package), the guest SDK and the KB build helper. `nix develop`
provides the contributor toolchain; `cabal.project` coordinates Cabal builds
inside it. KB templates pin the SDK input to the host's repository revision.
Guest compilation must still be tested through the KB flake and real guest protocol, not inferred
from a successful host-linked SDK build. This layout does not require every guest dependency or plugin
to become a native Cabal package.

### Shared source ownership

`shared/kyyn-types` holds genuinely shared pure vocabulary: fact identity/envelopes,
diagnostics and validation reports, and schema metadata where both
host and guest use the same definitions. Native packages and the guest SDK compile
the same source in their independently pinned GHC builds. The SDK may re-export this
vocabulary so authors need no separate knowledge of the repository arrangement.
The shared package depends only on pure libraries supported by both toolchains,
not host packages, effects, compiler internals or guest transport implementation.
CI must exercise it on both sides of the protocol; source sharing is not proof of compatibility.
Shared modules carry any required language pragmas in their source rather than
relying on Cabal defaults, and use features with matching semantics in the host and guest builds.

Host `KnowledgeBase` and `Root` snapshot descriptors stay host-side. Guest-authored
KB schemas stay in their KBs. Sharing a name or concept does not make these different
representations shared source. The common vocabulary is also distinct from the
wire codec decision: sharing types does not select their transport encoding.
Prefer this single source for compatible pure values over independently maintained
host/guest definitions. Mechanically generated representations are not prohibited
where an actual boundary needs them.

### Host ownership

Pure format decoding may live in plumbing capability helpers: the fixed metadata
decoder uses Aeson without granting native IO or compiler access to that package.

[ADR 0003](0003-effects.md) and the [boundary map](../boundaries.md) define permitted
dependencies and module ownership. The package names above implement those boundaries,
not a package per capability. In particular, `kyyn-porcelain-interpreters` can use
both capability APIs but cannot import native IO implementations. Format-specific
capability helpers with plumbing dependencies live there too, without becoming
miscellaneous functions exported from interpreter modules.

Native plumbing owns Nix provisioning/build invocation, process lifetime and
protocol description decoding, using the capabilities in ADRs 0002 and 0005.
The host links no guest compiler frontend. Porcelain selects the captured source,
entry scope and semantic operation; it never assembles compiler/Nix shell commands.

`guest/kyyn-guest-build` owns GHC API integration, build-time schema extraction,
generated bindings/codecs, the embedded description and API catalogue. It is built
with the KB-selected GHC/SDK dependencies. Compiler ASTs stay inside that package.
The runtime package implements describe/invoke framing, and the public SDK remains
the authoring interface. Source and notices for locked dependencies are supplied
through locked Nix dependencies. The haskell-agentic package family is a flake
input; JSON and transformers libraries are ordinary package dependencies, with
Aeson replacing the former JSON implementation where selected by ADR 0007.
MicroHs is removed from the toolchain and dependency tree. Reserve `vendor/`
only for genuinely patched upstream sources; there are none currently requiring
that exception. Plugin source installed into a KB remains governed by ADR 0015,
not this repository dependency policy.

Constructor visibility must agree with package ownership. The implementation of
`Validated` lives with checking in the porcelain package and exposes an abstract
type, as specified in [ADR 0004](0004-knowledge-base.md); pure host domain modules
must not gain a reverse dependency on porcelain. SDK-private observation constructors
similarly remain in the SDK package with the functions that construct them. This
does not make ordinary `Candidate` data a sealed proof or introduce another service.

`kyyn-surfaces` translates CLI/MCP/HTTP requests and responses. It receives the
relevant application execution functions from `kyyn`; it does not assemble handlers
or import store, Git or provider implementations. Add a Web UI package when its
implementation exists; no `web/` directory or Node build is required now. That
client will consume the same application operations, not own another set of
business workflows.

The composition package can begin small:

```text
host/kyyn/
├── kyyn.cabal
├── app/Main.hs
└── src/Kyyn/Application/
    ├── Compose.hs
    └── Execution/                    Split out only when useful
        ├── ListEvolutions.hs
        ├── PreviewEvolution.hs
        └── AcceptEvolution.hs
```

`Main.hs` is a thin entry point. Composition selects the context and interpreters
needed by the operation, without moving its semantic workflow out of
`kyyn-porcelain`. Interpreter installation stays in the interpreter packages.
[ADR 0003](0003-effects.md) owns the corresponding `run…` / `execute…` / operation
naming convention. These are packages within one installed application, not services.

### Guest and plugin ownership

`kyyn-sdk` contains the public, pure authoring surface. `kyyn-runtime` contains the
private guest execution/transport implementation. Neither depends on the native
kernel. Leave the exact shared wire-type/codec package placement to
[ADR 0007](0007-wire.md); do not create a speculative shared-protocol package or
maintain independent definitions merely to fill out this tree.

Each directory under `plugins/` is independently consumable source through the
ordinary plugin installation path in [ADR 0015](0015-plugins.md). First-party plugins
use the same public SDK and declared host capabilities as third-party plugins,
without privileged host imports. A tap can select a plugin directory from this
repository or a separate third-party repository. Installation does not require
every first-party plugin merely because they share a development repository.

### Tests and development material

Keep unit tests with their packages. Top-level integration tests exercise real
boundaries, including building and invoking plugins after normal source vendoring
into a KB. `examples/` contains small, readable KBs; field scenarios carry the
prepared inputs, agent tasks and expectations described in ADR 0024. Do not copy
real working KBs or private source evidence into the product repository as fixtures.
Example and field-scenario KBs are templates copied into separate, disposable Git
repositories before opening or evolving them. Do not operate on `examples/todos/`
as a live KB inside the product checkout: its acceptance must not target the product
branch or make product commits the base of its evolutions.

When their implementations exist, use these explicit build/test entry points:

| Location | Responsibility |
| --- | --- |
| `tools/test.sh` | Coordinate native tests and the applicable guest, integration and Web checks; do not equate host-only success with a complete test run |
| `tools/test-guest.sh` | Compile and exercise shared types, SDK and private guest runtime through the selected Nix guest environment |
| `tests/integration/guest/` | Guest build/execution fixtures, first-party plugins through normal vendoring, and example KBs instantiated into isolated repositories |
| `flake.nix` | Build the host package and expose the guest SDK, KB build helper and contributor development shell |

These are the intended locations, not scripts claimed to exist already. Package-local
GHC tests also cover the shared source. Guest/plugin failures must fail the full
test entry point rather than be silently skipped behind a passing Cabal build.

`tools/` contains operational build/bootstrap/packaging scripts, not an alternative
implementation of domain workflows. Locked flake/package dependencies are upstream
source inputs; compiled tools and generated bindings are derived artifacts,
not additional independently authored source trees.

## Consequences and verification

One change can update an interface, its implementation, guest bindings and tests in
one commit. Independent packaging remains possible without cross-repository release
coordination. Split a component into another repository only when a concrete
independent lifecycle justifies the cost.

Package visibility and import checks must enforce the dependency directions in
ADR 0003. Test first-party plugins through the public installation/execution path,
and run the same application operations behind CLI/MCP/Web adapters. Do not create
empty packages, placeholder effects or runtime services to make the repository
look like this diagram before they are needed.
