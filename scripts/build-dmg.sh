#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build-app.sh release
staging="$(mktemp -d "${TMPDIR:-/tmp}/myterm-dmg.XXXXXX")"
image_path="$PWD/dist/.MyTerm-$$.dmg"
trap 'rm -rf -- "$staging"; rm -f -- "$image_path"' EXIT
ditto "$PWD/dist/MyTerm.app" "$staging/MyTerm.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname MyTerm -srcfolder "$staging" -format UDZO -ov "$image_path"
hdiutil verify "$image_path"
mv -f "$image_path" "$PWD/dist/MyTerm.dmg"
printf 'Installer: %s\n' "$PWD/dist/MyTerm.dmg"
