# Native runtime dependency sources

This inventory records the declared licenses and license files inspected in the
exact Hackage source archives used for the initial effectful runtime/compilation
work. It is source evidence, not distribution clearance or a complete transitive
dependency audit. [ADR 0022](../architecture/adr/0022-open-source.md) owns licensing
policy and distribution review; [vendored inputs](../vendor/README.md) have their
own provenance and retained notices.

| Package | Inspected version | Declared license | Source archive |
| --- | --- | --- | --- |
| effectful-core | 2.6.1.0 | BSD-3-Clause | [source](https://hackage.haskell.org/package/effectful-core-2.6.1.0/effectful-core-2.6.1.0.tar.gz) |
| typed-process | 0.2.13.0 | MIT | [source](https://hackage.haskell.org/package/typed-process-0.2.13.0/typed-process-0.2.13.0.tar.gz) |
| async | 2.2.6 | BSD-3-Clause | [source](https://hackage.haskell.org/package/async-2.2.6/async-2.2.6.tar.gz) |
| temporary | 1.3 | BSD-3-Clause | [source](https://hackage.haskell.org/package/temporary-1.3/temporary-1.3.tar.gz) |
| random | 1.3.1 | BSD3 (Cabal declaration; retained LICENSE includes GHC and Haskell 98 notices) | [source](https://hackage.haskell.org/package/random-1.3.1/random-1.3.1.tar.gz) |
| cryptohash-sha256 | 0.11.102.1 | BSD-3-Clause | [source](https://hackage.haskell.org/package/cryptohash-sha256-0.11.102.1/cryptohash-sha256-0.11.102.1.tar.gz) |
| dhall | 1.42.3 | BSD-3-Clause | [source](https://hackage.haskell.org/package/dhall-1.42.3/dhall-1.42.3.tar.gz) |
| prettyprinter | 1.7.2 | BSD-2-Clause | [source](https://hackage.haskell.org/package/prettyprinter-1.7.2/prettyprinter-1.7.2.tar.gz) |
| optparse-applicative | 0.19.0.0 | BSD3 | [source](https://hackage.haskell.org/package/optparse-applicative-0.19.0.0/optparse-applicative-0.19.0.0.tar.gz) |
| transformers | 0.6.1.1 | BSD-3-Clause | [source](https://hackage.haskell.org/package/transformers-0.6.1.1/transformers-0.6.1.1.tar.gz) |
| filelock | 0.1.1.8 | PublicDomain (Cabal declaration); LICENSE is CC0-1.0 | [source](https://hackage.haskell.org/package/filelock-0.1.1.8/filelock-0.1.1.8.tar.gz) |

Each archive contains `LICENSE` (`LICENSE.md` for prettyprinter); its Cabal declaration and that file were inspected.
These are native Cabal dependencies. Transformers also supplies the vendored
guest subset documented in [vendored inputs](../vendor/README.md). The table does
not pin the solver: Cabal files govern dependency constraints, and the resolved
build plan must be reviewed for any distribution.
