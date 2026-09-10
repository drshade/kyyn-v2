#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "Usage: bash tools/stage-cli.sh NEW_DIRECTORY" >&2
  exit 2
fi
stage_prefix=$1
if [[ "$stage_prefix" != /* ]]; then stage_prefix="$PWD/$stage_prefix"; fi
if [[ -e "$stage_prefix" || -L "$stage_prefix" ]]; then
  echo "Staging destination already exists: $stage_prefix" >&2
  exit 1
fi
cd "$(dirname "$0")/.."
cabal build exe:kyyn-v2 exe:kyyn-api-catalogue
make -C vendor/MicroHs bin/gmhs bin/mhseval bin/cpphs
mkdir -p "$stage_prefix/bin" "$stage_prefix/lib/kyyn/microhs/bin" "$stage_prefix/lib/kyyn/sdk/Text/JSON" "$stage_prefix/share/kyyn/licenses"
cp "$(cabal list-bin exe:kyyn-v2)" "$stage_prefix/bin/kyyn-v2"
cp vendor/MicroHs/bin/gmhs "$stage_prefix/lib/kyyn/microhs/bin/mhs"
for executable in mhseval cpphs; do
  cp "vendor/MicroHs/bin/$executable" "$stage_prefix/lib/kyyn/microhs/bin/"
done
cp -R vendor/MicroHs/lib "$stage_prefix/lib/kyyn/microhs/"
cp -R shared/kyyn-types/src/. "$stage_prefix/lib/kyyn/sdk/"
cp -R guest/kyyn-sdk/src/. "$stage_prefix/lib/kyyn/sdk/"
cp -R guest/kyyn-runtime/src/. "$stage_prefix/lib/kyyn/sdk/"
cp -R vendor/transformers/Control "$stage_prefix/lib/kyyn/sdk/"
cp vendor/json/Text/JSON/Types.hs vendor/json/Text/JSON/String.hs "$stage_prefix/lib/kyyn/sdk/Text/JSON/"
MHSCPPHS="./microhs/bin/cpphs" "$(cabal list-bin exe:kyyn-api-catalogue)" \
  "$stage_prefix/lib/kyyn" guest/kyyn-sdk/kyyn-sdk.cabal shared/kyyn-types/kyyn-types.cabal
cp vendor/MicroHs/LICENSE "$stage_prefix/share/kyyn/licenses/MicroHs"
cp vendor/json/LICENSE "$stage_prefix/share/kyyn/licenses/json"
cp vendor/transformers/LICENSE "$stage_prefix/share/kyyn/licenses/transformers"
cp docs/dependency-sources.md "$stage_prefix/share/kyyn/licenses/native-source-inventory.md"
echo "Staged development executable: $stage_prefix/bin/kyyn-v2"
