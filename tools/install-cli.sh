#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: bash tools/install-cli.sh [PREFIX (default: ~/.local)]" >&2
  exit 2
fi
install_prefix=${1:-"$HOME/.local"}
mkdir -p "$install_prefix"
install_prefix=$(cd "$install_prefix" && pwd -P)
install_bundle="$install_prefix/lib/kyyn-v2"
install_link="$install_prefix/bin/kyyn-v2"
if [[ -e "$install_link" || -L "$install_link" ]]; then
  if [[ ! -L "$install_link" || $(readlink "$install_link") != "$install_bundle/bin/kyyn-v2" ]]; then
    echo "Refusing to replace an unrelated executable: $install_link" >&2
    exit 1
  fi
fi
if [[ -e "$install_bundle" || -L "$install_bundle" ]]; then
  if [[ -L "$install_bundle" || ! -f "$install_bundle/bin/kyyn-v2" || ! -d "$install_bundle/lib/kyyn" ]]; then
    echo "Refusing to replace an unrelated directory: $install_bundle" >&2
    exit 1
  fi
fi
mkdir -p "$install_prefix/bin" "$install_prefix/lib"
install_stage=$(mktemp -d "$install_prefix/lib/.kyyn-v2-install.XXXXXXXX")
cleanup() {
  local status=$?
  if [[ $status != 0 && -d "$install_stage/previous" ]]; then
    echo "Installation failed; previous bundle retained at $install_stage/previous" >&2
  else
    rm -rf -- "$install_stage"
  fi
}
trap cleanup EXIT

bash "$(dirname "$0")/stage-cli.sh" "$install_stage/bundle"
if [[ -d "$install_bundle" ]]; then
  mv "$install_bundle" "$install_stage/previous"
fi
mv "$install_stage/bundle" "$install_bundle"
ln -sfn "$install_bundle/bin/kyyn-v2" "$install_link"
echo "Installed: $install_link"
case ":$PATH:" in
  *":$install_prefix/bin:"*) ;;
  *) echo "Add $install_prefix/bin to PATH, or invoke the installed path directly." ;;
esac
