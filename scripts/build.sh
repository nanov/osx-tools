#!/bin/zsh
# Build "Nanov OSX Utils.app" into ./build. Signs with "Nanov OSX Utils Dev" when it exists
# (see make-signing-cert.sh) so the Accessibility grant survives rebuilds; otherwise ad-hoc,
# whose signature changes every build. SIGN_ID overrides both.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --arch arm64
bin=$(swift build -c release --arch arm64 --show-bin-path)
app="build/Nanov OSX Utils.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/NanovOSXUtils" "$app/Contents/MacOS/"
strip -x "$app/Contents/MacOS/NanovOSXUtils"
cp Resources/Info.plist "$app/Contents/"
sign_id=${SIGN_ID:-}
if [[ -z $sign_id ]] && security find-identity -p codesigning | grep -q "Nanov OSX Utils Dev"; then
  sign_id="Nanov OSX Utils Dev"
fi
codesign --force --sign "${sign_id:--}" "$app"
echo "built $app"
