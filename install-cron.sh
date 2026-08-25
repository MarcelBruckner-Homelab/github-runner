#!/usr/bin/env bash
# install-cron.sh — add (or remove with --remove) the hourly prune-dind.sh
# cron job for this host's root crontab. Idempotent: safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_CMD="$SCRIPT_DIR/prune-dind.sh >> /var/log/prune-github-runner.log 2>&1"
CRON_LINE="0 * * * * $CRON_CMD"

current="$(crontab -l 2>/dev/null || true)"

if [[ "${1:-}" == "--remove" ]]; then
  if ! grep -qF "$CRON_CMD" <<<"$current"; then
    echo "No matching cron entry found — nothing to remove."
    exit 0
  fi
  printf '%s\n' "$current" | grep -vF "$CRON_CMD" | crontab -
  echo "Removed cron entry for prune-dind.sh."
  exit 0
fi

if grep -qF "$CRON_CMD" <<<"$current"; then
  echo "Cron entry already installed:"
  echo "  $CRON_LINE"
  exit 0
fi

printf '%s\n%s\n' "$current" "$CRON_LINE" | crontab -
echo "Installed cron entry:"
echo "  $CRON_LINE"
echo "Logs: /var/log/prune-github-runner.log"
