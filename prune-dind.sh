#!/usr/bin/env bash
# prune-dind.sh — run hourly via cron; prunes every github-dind-* sidecar
# plus host-level dangling state. registry-mirror-data is never touched.
set -euo pipefail

for container in $(docker ps -a --filter "name=github-dind-" --format '{{.Names}}'); do
  echo "==> Pruning $container"
  docker exec "$container" docker -H tcp://localhost:2375 system prune -af --volumes
done

echo "==> Host-level prune (stopped containers, dangling images, build cache)"
docker system prune -af
