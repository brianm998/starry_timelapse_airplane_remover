#!/usr/bin/env bash
# Fetches out-of-repo test datasets listed in test_data/datasets.json: fetch.sh [--list] <name>…
#
# Cache: $STAR_TEST_DATA if set, else <repo>/.test-data. A dataset unpacks to <cache>/<name>/ and is
# complete only when <cache>/<name>/.complete holds the manifest's sha256 (written last). Idempotent.
# Needs bash, curl, tar, awk, sed and sha256sum or shasum.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
manifest="$here/datasets.json"
cache="${STAR_TEST_DATA:-$repo/.test-data}"

die() { echo "fetch.sh: error: $*" >&2; exit 1; }

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# manifest_field <name|-> <field>: the manifest is flat enough to read with sed (no jq/python on every runner).
# "-" reads a top-level field. Dataset objects are written one field per line.
manifest_field() {
  local name="$1" field="$2"
  if [ "$name" = "-" ]; then
    sed -n "s/^ *\"$field\": *\"\\([^\"]*\\)\".*/\\1/p" "$manifest" | head -1
  else
    awk -v n="\"$name\": {" -v f="\"$field\":" '
      index($0, n) { inside = 1; next }
      inside && /^ *}/ { inside = 0 }
      inside && index($0, f) {
        sub(/^[^:]*: */, ""); sub(/,? *$/, ""); gsub(/^"|"$/, ""); print; exit
      }' "$manifest"
  fi
}

names() { sed -n 's/^    "\([^"]*\)": {.*/\1/p' "$manifest"; }

human() { awk -v b="$1" 'BEGIN { printf "%.1f MiB", b / 1048576 }'; }

if [ "${1:-}" = "--list" ]; then
  for n in $(names); do
    printf '%-20s %10s  %s\n' "$n" "$(human "$(manifest_field "$n" bytes)")" "$(manifest_field "$n" description)"
  done
  exit 0
fi
[ $# -ge 1 ] || die "usage: fetch.sh [--list] <name>…  (known: $(names | tr '\n' ' '))"

release="$(manifest_field - release)"; repo_slug="$(manifest_field - repo)"
[ -n "$release" ] && [ -n "$repo_slug" ] || die "$manifest has no release/repo"

for name in "$@"; do
  asset="$(manifest_field "$name" asset)"
  want="$(manifest_field "$name" sha256)"
  [ -n "$asset" ] && [ -n "$want" ] || die "unknown dataset '$name' (known: $(names | tr '\n' ' '))"

  dest="$cache/$name"
  if [ -f "$dest/.complete" ] && [ "$(cat "$dest/.complete")" = "$want" ]; then
    echo "fetch.sh: $name: already complete in $cache, skipping"
    continue
  fi

  url="https://github.com/$repo_slug/releases/download/$release/$asset"
  mkdir -p "$cache"
  tmp="$(mktemp -d "$cache/.fetch-$name.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  echo "fetch.sh: $name: downloading $url"
  curl -fL --retry 3 --retry-delay 5 -sS -o "$tmp/$asset" "$url" || die "$name: download failed: $url"
  got="$(sha "$tmp/$asset")"
  [ "$got" = "$want" ] || die "$name: checksum mismatch for $asset: manifest says $want, downloaded file is $got"

  mkdir "$tmp/unpack"
  tar -xzf "$tmp/$asset" -C "$tmp/unpack" || die "$name: could not unpack $asset"
  [ -d "$tmp/unpack/$name" ] || die "$name: $asset has no top-level directory '$name'"

  rm -rf "$dest"
  mv "$tmp/unpack/$name" "$dest"
  printf '%s' "$want" > "$dest/.complete"     # last: an interrupted fetch never looks complete
  rm -rf "$tmp"; trap - EXIT
  echo "fetch.sh: $name: ready at $dest"
done
