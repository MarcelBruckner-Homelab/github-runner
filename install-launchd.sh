#!/usr/bin/env bash
# install-launchd.sh — macOS counterpart to install-cron.sh. Installs (or
# removes with --remove) a per-user launchd LaunchAgent that runs
# prune-dind.sh hourly. Idempotent: safe to re-run.
#
# Why launchd instead of cron on macOS: modern macOS (Ventura+) restricts
# background `cron` unless the launching app is granted Full Disk Access, and
# jobs silently don't run otherwise. A LaunchAgent needs no root, no Full Disk
# Access, and is the platform-native scheduler. See the "Running on macOS"
# section of README.md.
#
# Usage:
#   ./install-launchd.sh            # install + load the hourly agent
#   ./install-launchd.sh --remove   # unload + delete the agent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.github-runner.prune-dind"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="$HOME/Library/Logs/prune-github-runner.log"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "This installer is macOS-only. On Linux use ./install-cron.sh." >&2; exit 1; }

if [[ "${1:-}" == "--remove" ]]; then
  if [[ ! -f "$PLIST" ]]; then
    echo "No LaunchAgent found at $PLIST — nothing to remove."
    exit 0
  fi
  launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed LaunchAgent $LABEL and $PLIST."
  exit 0
fi

[[ -x "$SCRIPT_DIR/prune-dind.sh" ]] || { echo "prune-dind.sh not found or not executable in $SCRIPT_DIR." >&2; exit 1; }

# launchd gives jobs a minimal PATH that won't include Docker Desktop's binary,
# so bake the docker location (plus common fallbacks) into the agent's PATH.
docker_bin="$(command -v docker || true)"
[[ -n "$docker_bin" ]] || { echo "docker not found on PATH — install/start Docker Desktop first." >&2; exit 1; }
docker_dir="$(dirname "$docker_bin")"
agent_path="${docker_dir}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_DIR}/prune-dind.sh</string>
        <string>--dind-only</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${agent_path}</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
EOF

# Reload cleanly whether or not a previous version is already bootstrapped.
launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "${DOMAIN}/${LABEL}"

echo "Installed LaunchAgent: $LABEL"
echo "  plist:    $PLIST"
echo "  schedule: hourly, at minute 0"
echo "  logs:     $LOG"
echo
echo "Run it now to test:  launchctl kickstart -p ${DOMAIN}/${LABEL}"
echo "Remove it later:     ./install-launchd.sh --remove"
