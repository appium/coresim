#!/usr/bin/env bash
# Seeds a path-based kTCCServiceAudioCapture ("System Audio Recording Only") grant for the given
# binary into the host's TCC databases, so CI exercises the real (not permission-denied) audio-
# capture path (see CLAUDE.md, sim_audio_tap.mm).
#
# Only works where SIP is disabled (GitHub-hosted macOS images have been since macos-13) — that's
# what normally makes TCC.db unwritable even as root. Mirrors appium-mac2-driver's
# scripts/ci/grant-accessibility.sh, except the grant targets the Node.js binary itself (the
# addon runs in-process, not via a signed .app bundle).
#
# Seeds both TCC databases (system-wide and per-user) since which one macOS actually consults for
# this service isn't documented — harmless either way.
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

# Escaped for the single-quoted SQL literal below (doubling any embedded quote) — the calling
# runner isn't guaranteed to be one of GitHub's own hosted images.
escaped_path="${target_path//\'/\'\'}"

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
  ('kTCCServiceAudioCapture', '${escaped_path}', 1, 2, 3, 1,
   'UNUSED', 0, CAST(strftime('%s', 'now') AS INTEGER));
SQL
}

seed_db "/Library/Application Support/com.apple.TCC/TCC.db"
seed_db "$HOME/Library/Application Support/com.apple.TCC/TCC.db"

sudo launchctl kickstart -k system/com.apple.tccd 2>/dev/null || sudo pkill -HUP tccd || true
pkill -HUP tccd 2>/dev/null || true # the per-user tccd instance, distinct from the system one above

echo "Granted kTCCServiceAudioCapture to $target_path"
