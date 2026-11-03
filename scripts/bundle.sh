#!/usr/bin/env bash
# Build the SQPro executable and assemble an ad-hoc-signed dist/Query Pro.app around it.
#
#   scripts/bundle.sh            # release build
#   scripts/bundle.sh --debug    # debug build
#   scripts/bundle.sh --open     # build, quit the running copy, launch the new one
set -euo pipefail

config=release
open_after=false
for arg in "$@"; do
  case "$arg" in
    --debug) config=debug ;;
    --release) config=release ;;
    --open) open_after=true ;;
    -h | --help)
      sed -n '2,6p' "$0"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 64
      ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Its own scratch path, so bundling never contends with an editor's or a test run's .build lock.
scratch="${SCRATCH_PATH:-.build-bundle}"

swift build -c "$config" --product SQPro --scratch-path "$scratch"
bin="$(swift build -c "$config" --product SQPro --scratch-path "$scratch" --show-bin-path)"

app="dist/Query Pro.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin/SQPro" "$app/Contents/MacOS/SQPro"
cp Resources/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' >"$app/Contents/PkgInfo"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/"

shopt -s nullglob
for bundle in "$bin"/*.bundle; do
  cp -R "$bundle" "$app/Contents/Resources/"
done
shopt -u nullglob

codesign --force --deep --sign - "$app"
codesign --verify --strict "$app"

echo "Built $root/$app ($config)"

if $open_after; then
  pkill -x SQPro 2>/dev/null && sleep 0.5 || true
  open "$app"
fi
