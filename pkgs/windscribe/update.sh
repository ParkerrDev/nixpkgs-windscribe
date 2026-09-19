#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash curl jq nix coreutils gnused python3
#
# Rewrites sources.nix from the newest upstream release.
#
#   ./pkgs/windscribe/update.sh              # latest stable release
#   ./pkgs/windscribe/update.sh 2.24.13      # a specific version
#
# Hashes come from actually fetching each .deb rather than from the SHA-256
# table in the release notes, so a mismatch between the two cannot slip through.
set -euo pipefail

repo="Windscribe/Desktop-App"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/sources.nix"

version="${1:-}"
if [ -z "$version" ]; then
  version="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name)"
  version="${version#v}"
fi

current="$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$out")"
echo "current: $current"
echo "latest:  $version"
if [ "$current" = "$version" ]; then
  echo "already up to date"
  exit 0
fi

prefetch() {
  local deb="$1" arch="$2"
  local url="https://github.com/$repo/releases/download/v$version/${deb}_${version}_${arch}.deb"
  echo "  fetching $url" >&2
  nix store prefetch-file --json --hash-type sha256 "$url" | jq -r .hash
}

gui_x86="$(prefetch windscribe amd64)"
gui_arm="$(prefetch windscribe arm64)"
cli_x86="$(prefetch windscribe-cli amd64)"
cli_arm="$(prefetch windscribe-cli arm64)"

sed -i \
  -e "s|^  version = \".*\";$|  version = \"$version\";|" \
  "$out"

python3 - "$out" "$gui_x86" "$gui_arm" "$cli_x86" "$cli_arm" <<'PY'
import re
import sys

path, gui_x86, gui_arm, cli_x86, cli_arm = sys.argv[1:6]
text = open(path).read()
hashes = [gui_x86, gui_arm, cli_x86, cli_arm]
index = 0


def replace(match):
    global index
    value = hashes[index]
    index += 1
    return f'hash = "{value}"'


text = re.sub(r'hash = "[^"]*"', replace, text)
assert index == 4, f"expected 4 hash fields, rewrote {index}"
open(path, "w").write(text)
PY

echo
echo "updated $out to $version"
echo "now run: nix build .#windscribe .#windscribe-cli && nix flake check"
