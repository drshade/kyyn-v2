# Upstream build inputs

These are source copies, not imported plugin executables. Builds do not fetch
replacement source during execution. Preserve the upstream license files and
notices; Kyyn's proprietary policy does not replace them.

| Directory | Source | Archive SHA-256 | License |
| --- | --- | --- | --- |
| MicroHs | [455782164e75998b140d869c1b7cdde0c8a21508](https://github.com/augustss/MicroHs/archive/455782164e75998b140d869c1b7cdde0c8a21508.tar.gz), version 0.16.6.0 | `562149892c559ab8376683b2eacd242ed421842c5f5f73905392056e72c1fb2e` | Apache-2.0; retain included notices |
| json | [json-0.11](https://hackage.haskell.org/package/json-0.11/json-0.11.tar.gz) | `d079ab12e2482349421044851cf52cf23d0bf762ca9b5c854c902def7277e690` | BSD-3-Clause |

No upstream source patches. MicroHs's normal build generates ignored `mhs.conf`
and binaries. Native frontend integration compiles its `ghc/` and `src/` modules;
guest builds use the compiler built from the same source revision. The guest
runtime imports only json's `Text.JSON.Types` and `Text.JSON.String` modules.

To update a source copy, replace it from the explicitly selected upstream archive,
retain its notices, update this provenance and rerun the complete gate. Source
archives for this repository must include `vendor/`; no neighboring experiment
checkout or local download cache is a build input.
