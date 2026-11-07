#!/bin/bash
set -euo pipefail
IPA="$1"
DYLIB="${2:-./bsdodge.dylib}"

rm -rf work && mkdir work && cd work
unzip -q "$IPA"
APP=$(ls -d Payload/*.app | head -1)
BIN="$APP/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Info.plist")"

ldid -e "$BIN" > ent.plist
cp "../$DYLIB" "$APP/"
insert_dylib --strip-codesig --inplace @executable_path/bsdodge.dylib "$BIN"
ldid -S "$APP/bsdodge.dylib"
ldid -S"ent.plist" "$BIN"

/usr/libexec/PlistBuddy -c "Add :UIFileSharingEnabled bool true" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSSupportsOpeningDocumentsInPlace bool true" "$APP/Info.plist" 2>/dev/null || true

cd .. && zip -qry bsdodge.ipa work/Payload
echo "done -> bsdodge.ipa"
