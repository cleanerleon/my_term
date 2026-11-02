#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
swift build -c "$configuration" --product MyTerm
swift build -c "$configuration" --product WindAskpass
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
# Build and sign off to the side; only a verified bundle replaces the fixed app.
mkdir -p "$PWD/dist"
destination="$PWD/dist/MyTerm.app"
app_dir="$PWD/dist/.MyTerm-build-$$.app"
trap 'rm -rf -- "$app_dir"' EXIT
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/MyTerm" "$app_dir/Contents/MacOS/MyTerm"
cp "$bin_dir/WindAskpass" "$app_dir/Contents/MacOS/WindAskpass"
# The app uses SwiftTerm's CoreText renderer. Keep optional shader assets in Resources.
if [[ -d "$bin_dir/SwiftTerm_SwiftTerm.bundle" ]]; then
    ditto "$bin_dir/SwiftTerm_SwiftTerm.bundle" "$app_dir/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
fi
cp THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MyTerm</string>
<key>CFBundleIdentifier</key><string>local.windnative.app</string>
<key>CFBundleName</key><string>MyTerm</string>
<key>CFBundleDisplayName</key><string>MyTerm</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
python3 - "$app_dir" "$destination" <<'PYTHON'
import ctypes,os,sys
staging,destination=sys.argv[1:]
if os.path.exists(destination) and not os.path.islink(destination):
    library=ctypes.CDLL(None, use_errno=True)
    swap=library.renamex_np
    swap.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]
    swap.restype=ctypes.c_int
    if swap(os.fsencode(staging),os.fsencode(destination),2):
        error=ctypes.get_errno()
        raise OSError(error,os.strerror(error))
else:
    os.replace(staging,destination)
PYTHON
printf 'Built: %s\n' "$destination"
