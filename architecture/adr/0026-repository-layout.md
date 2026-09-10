---
id: 0026
title: 'One repository, explicit package boundaries'
status: proposed
date: 2026-09-07
---
# One repository, explicit package boundaries

Basis: the monorepo layout, interpreter package names and shared-source boundaries
are owner-agreed. Source-copy/build integration below specifies the initial
implementation; full distribution mechanics remain to be proved.

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
├── cabal.project
├── architecture/                      ADRs, principles and walkthroughs
│
├── shared/
│   └── kyyn-types/                    Pure vocabulary compiled by GHC and MicroHs
│
├── host/
│   ├── kyyn-domain/                   Pure host entities and result types
│   ├── kyyn-porcelain/                Semantic capabilities and application operations
│   ├── kyyn-porcelain-interpreters/   Interpret porcelain through other capabilities
│   ├── kyyn-plumbing/                 Plumbing capability definitions
│   ├── kyyn-plumbing-interpreters/    Interpret plumbing through native IO
│   ├── kyyn-microhs/                  Schema inspection and guest compilation interpreters
│   ├── kyyn-surfaces/                 CLI, MCP and HTTP adapters
│   └── kyyn/                          Executable entry point and execution composition
│
├── guest/
│   ├── kyyn-sdk/                      Public API for KB and plugin authors
│   └── kyyn-runtime/                  Private guest transport and execution support
│
├── web/                              Human-facing UI
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
├── vendor/
│   └── MicroHs/                       Pinned upstream source used by native/guest builds
│
└── tools/                            Bootstrap, packaging and development scripts
```

This is a destination layout, not a scaffolding checklist. Create each directory
and package only when the current implementation has work for it. The named plugins
and todo KB illustrate placement, not existing implementations or a requirement
to build them all in the first slice. Real user KBs remain separate repositories.

Each implemented Haskell package has its own Cabal file, `src/` and package-local
`test/` where needed. `cabal.project` coordinates native builds; guest compilation
must still be tested through the bundled MicroHs toolchain, not inferred from a
successful GHC build. This layout does not require every guest dependency or plugin
to become a native Cabal package.

### Shared source ownership

`shared/kyyn-types` holds genuinely shared pure vocabulary: fact identity/envelopes,
diagnostics and validation reports, paging values and schema metadata where both
host and guest use the same definitions. Native packages and the guest SDK compile
the same source with GHC and MicroHs respectively. The SDK may re-export this
vocabulary so authors need no separate knowledge of the repository arrangement.
The shared package depends only on pure libraries supported by both toolchains,
not host packages, effects, compiler internals or guest transport implementation.
CI must exercise it under both compilers; source sharing is not proof of compatibility.
Shared modules carry any required language pragmas in their source rather than
relying on Cabal defaults, and use features with matching semantics in both compilers.

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

`kyyn-microhs` is a native plumbing implementation package. It owns compiler-specific
integration, the `SchemaInspection` interpreter in [ADR 0005](0005-contracts.md)
and the `GuestCompilation` interpreter in [ADR 0002](0002-runtime.md). Their effect
definitions belong to `kyyn-plumbing`; compiler invocation details do not belong
to porcelain interpreters. Only application composition and native plumbing
interpreter packages may depend on it; ordinary operations, porcelain interpreters
and surfaces use capability interfaces instead. Pure binding generation and contract
projections belong with their capability helpers outside this compiler-specific
package, following ADR 0005. Purity alone is not a reason to expose a native package
to callers otherwise forbidden to import it.

The build-only `kyyn-api-catalogue` executable lives in `host/kyyn-microhs/app/`;
it generates the installed guest discovery catalogue specified in [ADR 0018](0018-surfaces.md).
It inspects from the staged runtime directory using relative paths, avoiding the
native compiler's shell-based CPP invocation splitting installation paths containing spaces.

The pinned upstream source lives at `vendor/MicroHs/` as an explicit build input.
Native compiler integration and the bundled guest toolchain use that same selected
revision. Its source and build integration must be available in a source build;
do not rely on Cabal reaching an experiment checkout or an undocumented ignored
download-cache path. Use a vendored source copy; a complete Git source archive
includes it. Record the revision, archive digest and notices in `vendor/README.md`.
Native Cabal packages build within that complete monorepo, not independently
packaged adapter source tarballs. Release binary/toolchain packaging remains a
separate proof. This is upstream dependency
management, not an assumed compiler fork. Preserve upstream notices and follow the
dependency review and distribution requirements in ADRs 0020 and 0022.

Constructor visibility must agree with package ownership. The implementation of
`Validated` lives with checking in the porcelain package and exposes an abstract
type, as specified in [ADR 0004](0004-knowledge-base.md); pure host domain modules
must not gain a reverse dependency on porcelain. SDK-private observation constructors
similarly remain in the SDK package with the functions that construct them. This
does not make ordinary `Candidate` data a sealed proof or introduce another service.

`kyyn-surfaces` translates CLI/MCP/HTTP requests and responses. It receives the
relevant application execution functions from `kyyn`; it does not assemble handlers
or import store, Git or provider implementations. `web/` contains the human-facing
client, not another set of business workflows. Its Node.js-based development/build
tooling produces packaged browser assets; [ADR 0020](0020-distribution.md) defines
the build-time versus installed-runtime boundary.

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
| `tools/test-guest.sh` | Compile and exercise shared types, SDK and private guest runtime with the bundled MicroHs toolchain |
| `tests/integration/guest/` | Guest build/execution fixtures, first-party plugins through normal vendoring, and example KBs instantiated into isolated repositories |
| `tools/build-web.sh` | Use Node.js build tooling to produce static browser assets |
| `tools/package.sh` | Include those assets with the native application and bundled runtime/toolchain |

These are the intended locations, not scripts claimed to exist already. Package-local
GHC tests also cover the shared source. Guest/plugin failures must fail the full
test entry point rather than be silently skipped behind a passing Cabal build.

`tools/` contains operational build/bootstrap/packaging scripts, not an alternative
implementation of domain workflows. `vendor/MicroHs/` is an upstream source input;
compiled tools, generated bindings and Web build outputs are derived artifacts,
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
