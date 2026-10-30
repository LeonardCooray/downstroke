#!/bin/bash
# Vendors the Switchcraft sound packs and licences. Usage: scripts/vendor-packs.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=https://github.com/mustafa4101996ahmed/switchcraft
SHA=67f3324ed851ccbaf7de20db8e7552a2a570453f

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone -q --filter=blob:none --sparse "$REPO" "$WORK/sc"
git -C "$WORK/sc" sparse-checkout set SoundPacks LICENSES
git -C "$WORK/sc" checkout -q "$SHA"

rm -rf Resources/SoundPacks
mkdir -p Resources/SoundPacks LICENSES
cp -R "$WORK"/sc/SoundPacks/*.switchcraft Resources/SoundPacks/
for f in "$WORK"/sc/LICENSES/*; do
    [[ "$(basename "$f")" == Sparkle-MIT.txt ]] && continue
    cp "$f" LICENSES/
done
cp "$WORK/sc/LICENSE" LICENSES/switchcraft-MIT.txt

cat > LICENSES/freesound-CC0.txt <<'LIC'
Some of the keyboard recordings used by the Switchcraft packs come from freesound.org
and are released under Creative Commons Zero (CC0 1.0, public domain dedication):

- "Mechanical keyboard clicking. Different keys" by humi74, https://freesound.org/s/412926/ (CC0 1.0)
- "Typing Fast_A01" by bonesawmgraw, https://freesound.org/s/572978/ (CC0 1.0)

https://creativecommons.org/publicdomain/zero/1.0/
LIC

add_texture() {
    local texture="$1"; shift
    for id in "$@"; do
        python3 - "Resources/SoundPacks/$id.switchcraft/manifest.json" "$texture" <<'PY'
import json, re, sys
path, texture = sys.argv[1:]
text = open(path).read()
if '"texture"' not in text:
    text = re.sub(r'^(  "samples")', '  "texture" : "%s",\n\\1' % texture, text, count=1, flags=re.M)
    open(path, "w").write(text)
assert json.loads(text)["texture"] == texture, path
PY
    done
}

add_texture thocky holy-panda topre cherry-mx-black-pbt cherry-mx-brown-pbt
add_texture creamy nk-cream alpaca turquoise red-ink black-ink
add_texture clacky cherry-mx-blue-abs cherry-mx-blue-pbt box-navy blue-alps buckling-spring
add_texture crisp cherry-mx-red-abs cherry-mx-brown-abs cherry-mx-clear
add_texture thump cherry-mx-black-abs cherry-mx-red-pbt cherry-mx-silent

echo "Vendored $(ls Resources/SoundPacks | wc -l | tr -d ' ') packs at ${SHA:0:7}"
