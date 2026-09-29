# Upstream build inputs

These are source copies, not imported plugin executables. Builds do not fetch
replacement source during execution. Preserve the upstream license files and
notices; Kyyn's proprietary policy does not replace them.

| Directory | Source | Archive SHA-256 | License |
| --- | --- | --- | --- |
| MicroHs | [8bf3d4d4242c8707b31c2338716977d24a95ad39](https://github.com/augustss/MicroHs/archive/8bf3d4d4242c8707b31c2338716977d24a95ad39.tar.gz), version 0.16.7.0 | `528f4669dc5e406a6a67f068e0ef4bfe50b4f3be00d8bc8381beaf2783b48351` | Apache-2.0; retain included notices |
| json | [json-0.11](https://hackage.haskell.org/package/json-0.11/json-0.11.tar.gz) | `d079ab12e2482349421044851cf52cf23d0bf762ca9b5c854c902def7277e690` | BSD-3-Clause |
| transformers | [transformers-0.6.1.1](https://hackage.haskell.org/package/transformers-0.6.1.1/transformers-0.6.1.1.tar.gz) | `81d2548e0f100a174fba36b332c0efd7c960e79d3c21ad6e1ff5f538b992d725` | BSD-3-Clause |

No upstream source patches. MicroHs's normal build generates ignored `mhs.conf`
and binaries. Native frontend integration compiles its `ghc/` and `src/` modules;
guest builds use the compiler built from the same source revision. The guest
runtime imports only json's `Text.JSON.Types` and `Text.JSON.String` modules.

The transformers copy contains only `Control.Monad.Signatures`,
`Control.Monad.Trans.Class`, `Control.Monad.Trans.Except`, `Control.Monad.Trans.Reader` and
`Control.Monad.Trans.State.Strict`, with the upstream LICENSE. Native SDK builds
use the same package version through Cabal; the bundled guest receives these
unmodified sources. Their CPP tests ask about base versions up to 4.13; the
GuestCompilation interpreter supplies `MIN_VERSION_base(x,y,z)=1` to select the
modern APIs supported by MicroHs. This is not a claim that MicroHs implements
every API of every base version. Reassess this definition when adding dependencies
or updating these sources. The dual-compiler evolution proof compiles this source
state/reader subset under both GHC and MicroHs; the Graph connector proof covers
ExceptT under both compilers. Other transformers modules are not covered.

To update a source copy, replace it from the explicitly selected upstream archive,
retain its notices, update this provenance and rerun the complete gate. Source
archives for this repository must include `vendor/`; no neighboring experiment
checkout or local download cache is a build input.
