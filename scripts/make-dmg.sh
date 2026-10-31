#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
[[ $# -le 1 ]] || { printf 'Usage: %s [--skip-build]\n' "$0" >&2; exit 2; }
case "${1:-}" in
    "") scripts/bundle.sh ;;
    --skip-build) ;;
    *) printf 'Usage: %s [--skip-build]\n' "$0" >&2; exit 2 ;;
esac
APP="$PROJECT_ROOT/build/Circe.app"
[[ -d "$APP" ]] || { printf 'Missing %s; run scripts/bundle.sh first.\n' "$APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

# Keep the pinned packaging tools local to build/, never in the global Python environment.
TOOLS="$PROJECT_ROOT/build/dmg-tools"
if [[ ! -x "$TOOLS/bin/python" ]]; then
    PYTHON=""
    for CANDIDATE in "${CIRCE_PYTHON:-python3}" python3.13 python3.12 python3.11 python3.10 /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13; do
        if command -v "$CANDIDATE" >/dev/null 2>&1 && "$CANDIDATE" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' 2>/dev/null; then
            PYTHON="$CANDIDATE"; break
        fi
    done
    [[ -n "$PYTHON" ]] || { printf 'Python 3.10+ is required; set CIRCE_PYTHON to its executable.\n' >&2; exit 1; }
    "$PYTHON" -m venv "$TOOLS"
fi
if ! cmp -s scripts/dmg-requirements.txt "$TOOLS/requirements-installed.txt"; then
    "$TOOLS/bin/python" -m pip install --disable-pip-version-check -r scripts/dmg-requirements.txt
    cp scripts/dmg-requirements.txt "$TOOLS/requirements-installed.txt"
fi

STAGING="$(mktemp -d "$PROJECT_ROOT/build/.circe-dmg.XXXXXX")"
MOUNT="$STAGING/verify"
cleanup() {
    if mount | /usr/bin/grep -Fq " on $MOUNT "; then hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet; fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
xcrun swift scripts/generate-dmg-background.swift "$STAGING/artwork"
"$TOOLS/bin/dmgbuild" -s scripts/dmg-settings.py -D "app=$APP" -D "background=$STAGING/artwork/background.png" Circe "$STAGING/Circe.dmg"
hdiutil verify "$STAGING/Circe.dmg"
mkdir -p "$MOUNT"
hdiutil attach "$STAGING/Circe.dmg" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]]
[[ -f "$MOUNT/.DS_Store" && -f "$MOUNT/.background.tiff" ]]
codesign --verify --deep --strict "$MOUNT/Circe.app"
"$TOOLS/bin/python" - "$MOUNT/.DS_Store" <<'PY'
from ds_store import DSStore
import sys
with DSStore.open(sys.argv[1], "r") as store:
    assert store["Circe.app"]["Iloc"] == (180, 270)
    assert store["Applications"]["Iloc"] == (540, 270)
    assert store["."]["icvp"]["backgroundType"] == 2
print("Verified application, Applications link, background, and Finder icon positions.")
PY
hdiutil detach "$MOUNT" -quiet
mv -f "$STAGING/Circe.dmg" "$PROJECT_ROOT/build/Circe.dmg"
printf 'Built and verified %s\n' "$PROJECT_ROOT/build/Circe.dmg"
