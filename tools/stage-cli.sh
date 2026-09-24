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
cabal build exe:kyyn-api-catalogue
build_revision=$(git rev-parse HEAD)
cabal build exe:kyyn-v2 --ghc-options="-DKYYN_BUILD_REVISION=\"$build_revision\""
bash tools/stage-microhs.sh "$stage_prefix/lib/kyyn/microhs"
mkdir -p "$stage_prefix/bin" "$stage_prefix/lib/kyyn/sdk/Text/JSON" "$stage_prefix/share/kyyn/licenses"
cp "$(cabal list-bin exe:kyyn-v2)" "$stage_prefix/bin/kyyn-v2"
cp -R shared/kyyn-types/src/. "$stage_prefix/lib/kyyn/sdk/"
cp -R guest/kyyn-sdk/src/. "$stage_prefix/lib/kyyn/sdk/"
cp -R guest/kyyn-runtime/src/. "$stage_prefix/lib/kyyn/sdk/"
cp -R vendor/transformers/Control "$stage_prefix/lib/kyyn/sdk/"
cp vendor/json/Text/JSON/Types.hs vendor/json/Text/JSON/String.hs "$stage_prefix/lib/kyyn/sdk/Text/JSON/"
"$(cabal list-bin exe:kyyn-api-catalogue)" \
  "$stage_prefix/lib/kyyn" guest/kyyn-sdk/kyyn-sdk.cabal
cp vendor/MicroHs/LICENSE "$stage_prefix/share/kyyn/licenses/MicroHs"
cp vendor/json/LICENSE "$stage_prefix/share/kyyn/licenses/json"
cp vendor/transformers/LICENSE "$stage_prefix/share/kyyn/licenses/transformers"
cp docs/dependency-sources.md "$stage_prefix/share/kyyn/licenses/native-source-inventory.md"
echo "Staged development executable: $stage_prefix/bin/kyyn-v2"
