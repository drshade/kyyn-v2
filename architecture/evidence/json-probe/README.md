# JSON compatibility reproducer

These are bounded investigation sources, not Kyyn runtime implementations.
[The investigation](../../protocol-investigation.md) records their scope and
limitations. `Probe.hs` demonstrates the unchanged library, `ProfileProbe.hs`
tests decoded-value checks, and `Host.hs` exercises native Aeson. `check.mjs`
asserts real pipe results, including the baseline crash rather than concealing it.

Prerequisites: Node.js 22+, GHC 9.10.3 with Aeson **2.2.5.0** available in its
package database, and built MicroHs revision
`455782164e75998b140d869c1b7cdde0c8a21508`. No dependency is vendored or adopted
by retaining this evidence. The commands below run from the repository root.

```bash
probe_dir=$(mktemp -d /tmp/kyyn-json-evidence.XXXXXX)
curl -fL https://hackage.haskell.org/package/json-0.11/json-0.11.tar.gz \
  -o "$probe_dir/json.tar.gz"
sha256sum "$probe_dir/json.tar.gz"
```

Check that the digest is exactly
`d079ab12e2482349421044851cf52cf23d0bf762ca9b5c854c902def7277e690`
before unpacking. Set `microhs_dir` to the absolute path of the pinned compiler
source/toolchain, not to an arbitrary `mhs` on PATH.

```bash
tar -xzf "$probe_dir/json.tar.gz" -C "$probe_dir"
evidence_dir="$PWD/architecture/evidence/json-probe"
export MHSDIR="$microhs_dir"
"$microhs_dir/bin/mhs" -i"$probe_dir/json-0.11" \
  "$evidence_dir/Probe.hs" -o"$probe_dir/probe"
"$microhs_dir/bin/mhs" -i"$probe_dir/json-0.11" \
  "$evidence_dir/ProfileProbe.hs" -o"$probe_dir/profile-probe"
ghc -package aeson-2.2.5.0 -outputdir "$probe_dir" \
  "$evidence_dir/Host.hs" -o "$probe_dir/host"
node "$evidence_dir/check.mjs" \
  "$probe_dir/probe" "$probe_dir/profile-probe" "$probe_dir/host"
```

If Aeson is in a Cabal store rather than GHC's default package database, supply
`-package-db /absolute/path/to/the/matching-ghc-store/package.db` to `ghc`.
Do not substitute a different Aeson version: duplicate-key policy and encoder
behavior are explicit conformance assertions, not assumed compatibility.

The profile check traverses retained string values and object keys at every
depth, rejecting surrogate Chars before output. First-key normalization discards
later duplicate fields, matching the pinned host policy. The baseline is expected
to fail for the escaped surrogate pair; the driver itself must succeed.

The ordinary documentation gate syntax-checks the Node driver but does not build
these probes or download their dependencies. Run the commands above to reproduce
the compatibility evidence. This is not a substitute for future runtime integration
tests, generated scalar codecs or the full protocol conformance suite in ADR 0007.
