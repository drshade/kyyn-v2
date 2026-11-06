---
id: 0020
title: 'Native host installation and KB-owned Nix provisioning'
---
# Native host installation and KB-owned Nix provisioning

## Context

Authors need mature guest libraries without manually assembling compilers and
package databases. Nix can provision the compiler and dependencies selected by a
KB; Kyyn must distinguish that setup from checking or invoking accepted code.
Agents should be able to diagnose setup on an ordinary user's machine.

## Decision

Install the native host and browser assets, and locate a supported Nix installation
and Git executable. Each KB's `flake.nix` and `flake.lock` own its guest build and
dependencies under ADR 0002. GHC is supplied by that environment, not by a global
Cabal setup or a MicroHs bundle shipped with the host. Authors may select arbitrary
Haskell libraries, subject to their chosen compiler/SDK actually building them.

Nix is a user prerequisite on Linux, macOS and Windows through WSL2. This is not a
native Windows execution promise. Installation may require OS permissions, daemon
setup or authentication; report those requirements explicitly rather than changing
host configuration silently. Resolve the Nix executable once through installation
configuration and invoke its absolute path; an agent can use it without changing
an existing terminal's PATH. Do not require users to understand compiler internals.

### Locked builds during ordinary operations

The host invokes Nix for the selected captured source and lock. A check may fetch
locked sources or cached outputs and build missing dependencies. It never updates
the lock or resolves an alternative version. There is no mandatory separate
preparation lifecycle. Authors explicitly update missing/outdated locks as an
ordinary source change; checking reports that need rather than doing it implicitly.

Cold builds may be expensive. Show dependency/build progress and distinguish a
cached execution from a fresh build. Measure representative cold/warm workloads;
Nix installation alone does not establish that the selected package set builds.
Offline execution/rebuild works when the necessary outputs/inputs are available;
missing data or unavailable remote access produces ordinary actionable errors.

Nix's normal binary-cache facilities are permitted. Operating a Kyyn-specific
cache is not a prerequisite. Cache configuration and trust are installation
choices; a cache miss never selects another compiler/library version.

```haskell
data SetupReport = SetupReport
  { installed :: [InstalledComponent]
  , outstanding :: [SetupRequirement]
  }

data SetupRequirement
  = MissingComponent ComponentName
  | PermissionRequired Text
  | AuthenticationRequired Text
  | UnsupportedConfiguration Text
```

InstalledComponent records the verified version and resolved location. Readiness
checks the installed tools without changing host configuration. A working guest build is
checked through ordinary build/describe operations. A nonempty outstanding list is not success.
Setup and readiness remain separate operations, not a persisted approval workflow.

Changing a flake or lock is an ordinary reviewed KB source/configuration change.
The host does not maintain compatibility readers, select historical SDKs or rewrite
pins. An incompatible protocol produces a precise diagnostic; the author repairs
the SDK pin/code and reprovisions. A host upgrade does not by itself rewrite a KB.
SDK source revisions are external dependency pins, not a protocol-version matrix.

### Distribution boundaries

Nix builds use captured source/configuration plus locked dependency inputs only.
Never copy a whole live KB into the store: exclude facts, evidence, credentials,
Git metadata and execution records. Facts and secrets remain host-managed runtime
inputs. Build outputs and their dependency closures are retained through owned GC
roots while in use (ADR 0002), and may be rebuilt after derived caches are removed.

Tap installation still vendors plugin source under ADR 0015. All adapters in a KB
use the same selected SDK/environment; plugin installation does not secretly create
an independent compiler environment. Nix may provide fixed compiled outputs from
its caches; this is distinct from accepting arbitrary tap executable entry points.
Keep build inputs/notices for distributable dependencies available under ADR 0022.

The development host executable remains `kyyn-v2` to coexist with v1. The user guide
owns implemented installation commands; this ADR defines the required distribution
contract, not a claim that a particular script already implements it. Native host
and Web build tools are developer dependencies. Browser assets are built before
installation; running Kyyn does not require a Node.js development server.

## Verification

Verify a fresh install on Linux, macOS and WSL2, including Nix availability, Git,
source-only KB initialization, locked dependency resolution, description, query,
evolution, plugin calls and rendering. Repeat checks/invocations offline, and
rebuild after deleting derived outputs while keeping provisioned build inputs. No separate preparation command is required.
Check missing inputs, unsupported outputs, incompatible descriptions and permission
failures. Test install reruns, cancellation and GC retention/release.

Run actual Windows-to-WSL launch, paths, browser and MCP checks before claiming that
journey. A Linux build alone is insufficient. A Nix build specification does not
prove every dependency works on every platform or that cached binaries exist.
