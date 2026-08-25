#!/usr/bin/env bash
# deregister.sh <runner-name> — stop and remove a runner + its dind sidecar.
# The runner image deregisters itself from GitHub on graceful SIGTERM (`down`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

name="${1:-}"
[[ -z "$name" ]] && { echo "Usage: $0 <runner-name>" >&2; exit 1; }

runner_dir="runners/$name"
[[ -d "$runner_dir" ]] || { echo "No such runner: $runner_dir" >&2; exit 1; }

echo "==> Stopping runner-${name} (deregisters from GitHub) and dind-${name}"
docker compose -f "$runner_dir/docker-compose.yaml" --env-file "$runner_dir/.env" down

echo "==> Removing $runner_dir"
rm -rf "$runner_dir"
