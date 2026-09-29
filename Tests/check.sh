#!/bin/bash
# Headless check of VoiceAI's vocabulary logic — no microphone, no model, no Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/check"
swiftc -o "$OUT" VoiceAI/Vocabulary.swift VoiceAI/ClaudeHook.swift VoiceAI/Recorder.swift VoiceAI/Paster.swift VoiceAI/Journal.swift VoiceAI/Stats.swift VoiceAI/FileTranscript.swift VoiceAI/Language.swift VoiceAI/UpdateSupport.swift Tests/main.swift -module-name Check -suppress-warnings 2>&1 | grep -v "^$" || true
"$OUT"
