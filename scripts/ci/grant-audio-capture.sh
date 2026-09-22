#!/usr/bin/env bash
# Seeds a path-based kTCCServiceAudioCapture ("System Audio Recording Only") grant for the given
# binary into the host's TCC databases, so this addon's Core Audio process-tap feature
# (src/native/sim_audio_tap.mm — the `audio` option on startVideoRecording/startVideoStream)
# actually captures real device audio in CI instead of the permission-denied silent-PCM path every
# unprivileged local dev run exercises by default (see CLAUDE.md).
#
# Only works on runners where System Integrity Protection is disabled (GitHub-hosted macOS images
# have shipped this way since macos-13: actions/runner-images#8162) — SIP is what normally makes
# TCC.db unwritable even as root. Mirrors appium-mac2-driver's scripts/ci/grant-accessibility.sh
# (same schema/SIP caveat, same client_type=1 path-based/no-csreq rationale — see its own comment)
# with one difference: this needs the grant on the actual Node.js binary running the test process
# itself (the native addon runs in-process, not via a signed .app bundle like WebDriverAgentMac's
# test runner).
#
# Which of the two TCC databases (system-wide vs. per-user) macOS actually consults for
# kTCCServiceAudioCapture isn't documented, so both are seeded — harmless either way, tccd just
# ignores an irrelevant row in the one it doesn't check.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <absolute-path-to-node-binary>" >&2
  exit 1
fi

target_path="$1"

if [[ ! -f "$target_path" ]]; then
  echo "::warning::grant-audio-capture.sh: no file at '$target_path', skipping grant" >&2
  exit 0
fi

seed_db() {
  local db="$1"
  if [[ ! -f "$db" ]]; then
    return 0
  fi
  sudo sqlite3 "$db" <<SQL
INSERT OR REPLACE INTO access
  (service, client, client_type, auth_value, auth_reason, auth_version,
   indirect_object_identifier, flags, last_modified)
VALUES
  ('kTCCServiceAudioCapture', '${target_path}', 1, 2, 3, 1,
   'UNUSED', 0, CAST(strftime('%s', 'now') AS INTEGER));
SQL
}

seed_db "/Library/Application Support/com.apple.TCC/TCC.db"
seed_db "$HOME/Library/Application Support/com.apple.TCC/TCC.db"

sudo launchctl kickstart -k system/com.apple.tccd 2>/dev/null || sudo pkill -HUP tccd || true
pkill -HUP tccd 2>/dev/null || true # the per-user tccd instance, distinct from the system one above

echo "Granted kTCCServiceAudioCapture to $target_path"
