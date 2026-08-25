#!/usr/bin/env bash
# prune-dind.sh — run hourly (cron on Linux, launchd on macOS via
# install-launchd.sh); prunes every github-dind-* sidecar plus, by default,
# host-level dangling state. registry-mirror-data is never touched.
#
#   --dind-only   prune only the github-dind-* sidecar caches; skip the
#                 host-level `docker system prune`. Use this on a machine you
#                 also develop on (e.g. a Mac), where the host-wide prune would
#                 wipe images/build cache/networks from unrelated projects.
set -euo pipefail

dind_only=""
[[ "${1:-}" == "--dind-only" ]] && dind_only="true"

for container in $(docker ps -a --filter "name=github-dind-" --format '{{.Names}}'); do
  echo "==> Pruning $container"
  docker exec "$container" docker -H tcp://localhost:2375 system prune -af --volumes
done

if [[ -n "$dind_only" ]]; then
  echo "==> --dind-only: skipping host-level prune"
  exit 0
fi

echo "==> Host-level prune (stopped containers, dangling images, build cache)"
docker system prune -af
