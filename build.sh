#!/bin/bash
# Builds VoiceAI (Release), installs it and starts it.
#
# Installs to ~/Applications unless the untracked file .install-dir names another folder
# (one line, a path); --no-open installs without starting the app. Signs with the identity
# set in the Xcode project when that certificate is in your keychain, otherwise ad hoc.
# CODE_SIGN_IDENTITY in the environment overrides both.
# The MLX packages ship a build plug-in and macros that Xcode otherwise asks to trust by hand;
# the two -skip… flags do that for the command line.
set -euo pipefail
cd "$(dirname "$0")"

OPEN=1
if [ "${1:-}" = "--no-open" ]; then OPEN=0; fi
TARGET="$HOME/Applications"
if [ -f .install-dir ]; then TARGET="$(head -n 1 .install-dir)"; fi

./Tests/check.sh
SIGN=()
PROJECT_ID="$(grep -m1 -o 'CODE_SIGN_IDENTITY = [0-9A-F]*' VoiceAI.xcodeproj/project.pbxproj | cut -d' ' -f3)"
if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
  SIGN=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
# No -v: find-identity -v hides self-signed certificates.
elif ! security find-identity -p codesigning | grep -q "$PROJECT_ID"; then
  echo "Signing certificate from the project not found — signing ad hoc."
  SIGN=(CODE_SIGN_IDENTITY=-)
fi
# C and C++ in the packages (MLX) write their source paths into the binary; mapped to ".",
# so the release carries no account name or folder layout.
PREFIX_MAP="\"-ffile-prefix-map=$PWD=.\""
LOG="$(mktemp)"
# ${SIGN[@]+...}: macOS bash 3.2 treats an empty array as unbound under set -u.
if ! xcodebuild -project VoiceAI.xcodeproj -scheme VoiceAI -configuration Release \
     -derivedDataPath build/dd -skipPackagePluginValidation -skipMacroValidation \
     OTHER_CFLAGS="\$(inherited) $PREFIX_MAP" OTHER_CPLUSPLUSFLAGS="\$(inherited) $PREFIX_MAP" \
     build ${SIGN[@]+"${SIGN[@]}"} > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" || tail -20 "$LOG"
  echo "Build failed — nothing installed. Full log: $LOG"
  exit 1
fi
grep -E "BUILD SUCCEEDED" "$LOG"
APP="build/dd/Build/Products/Release/VoiceAI.app"

pkill -x VoiceAI || true
mkdir -p "$TARGET/VoiceAI.app"
rsync -a --delete "$APP/" "$TARGET/VoiceAI.app/"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
"$LSREGISTER" -f "$TARGET/VoiceAI.app"
if [ "$OPEN" = 1 ]; then open "$TARGET/VoiceAI.app"; fi
echo "Installed: $TARGET/VoiceAI.app"
codesign -dvv "$TARGET/VoiceAI.app" 2>&1 | grep -m1 -E "^Authority=|^Signature=adhoc" || true
