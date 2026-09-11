#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "Usage: bash tools/stage-microhs.sh NEW_DIRECTORY" >&2
  exit 2
fi
toolchain_prefix=$1
if [[ "$toolchain_prefix" != /* ]]; then toolchain_prefix="$PWD/$toolchain_prefix"; fi
if [[ -e "$toolchain_prefix" || -L "$toolchain_prefix" ]]; then
  echo "Toolchain destination already exists: $toolchain_prefix" >&2
  exit 1
fi
cd "$(dirname "$0")/.."
make -C vendor/MicroHs bin/gmhs bin/mhseval bin/cpphs
mkdir -p "$toolchain_prefix/bin"
cp vendor/MicroHs/bin/gmhs "$toolchain_prefix/bin/mhs"
for executable in mhseval cpphs; do
  cp "vendor/MicroHs/bin/$executable" "$toolchain_prefix/bin/"
done
cp -R vendor/MicroHs/lib "$toolchain_prefix/"
