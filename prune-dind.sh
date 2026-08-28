#!/usr/bin/env bash
# prune-dind.sh — run hourly (cron on Linux, launchd on macOS via
# install-launchd.sh); prunes every github-dind-* sidecar plus, by default,
# host-level dangling state. registry-mirror-data is never touched.
#
# Age-based by default: only removes containers/images/build cache untouched
# for longer than $PRUNE_MAX_AGE (default 24h), so a freshly pulled image
# (e.g. postgres:18 for a test-db-migrations job) survives until the *next*
# job on the same runner rather than being gone by the time the container is
# created. Escalates to an unconditional sweep (old behavior) for a target
# only once its docker data-root is at/above $PRUNE_DISK_THRESHOLD_PCT
# (default 80%) full — the actual condition a prune is protecting against.
#
#   --dind-only   prune only the github-dind-* sidecar caches; skip the
#                 host-level prune. Use this on a machine you also
#                 develop on (e.g. a Mac), where the host-wide prune would
#                 wipe images/build cache/networks from unrelated projects.
set -euo pipefail

dind_only=""
[[ "${1:-}" == "--dind-only" ]] && dind_only="true"

MAX_AGE="${PRUNE_MAX_AGE:-24h}"
DISK_THRESHOLD_PCT="${PRUNE_DISK_THRESHOLD_PCT:-80}"

# prune_dind <container> — age-based prune of one github-dind-* sidecar's
# docker daemon, escalating to an unconditional sweep if its data-root disk
# is over threshold.
prune_dind() {
  local container=$1
  local d=(docker exec "$container" docker -H tcp://localhost:2375)
  local root pct
  root="$("${d[@]}" info --format '{{.DockerRootDir}}' 2>/dev/null)"
  pct="$(docker exec "$container" df -P "$root" 2>/dev/null | awk 'NR==2 { gsub("%",""); print $5 }')"

  if [[ -n "$pct" && "$pct" -ge "$DISK_THRESHOLD_PCT" ]]; then
    echo "==> Pruning $container (disk at ${pct}%, full sweep)"
    "${d[@]}" system prune -af --volumes
  else
    echo "==> Pruning $container (disk at ${pct:-unknown}%, keeping last ${MAX_AGE})"
    "${d[@]}" container prune -f --filter "until=${MAX_AGE}"
    "${d[@]}" image prune -af --filter "until=${MAX_AGE}"
    "${d[@]}" builder prune -af --filter "until=${MAX_AGE}"
    "${d[@]}" volume prune -f
  fi
}

for container in $(docker ps -a --filter "name=github-dind-" --format '{{.Names}}'); do
  prune_dind "$container"
done

if [[ -n "$dind_only" ]]; then
  echo "==> --dind-only: skipping host-level prune"
  exit 0
fi

host_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
host_pct="$(df -P "$host_root" 2>/dev/null | awk 'NR==2 { gsub("%",""); print $5 }')"

if [[ -n "$host_pct" && "$host_pct" -ge "$DISK_THRESHOLD_PCT" ]]; then
  echo "==> Host-level prune (disk at ${host_pct}%, full sweep)"
  docker system prune -af
else
  echo "==> Host-level prune (disk at ${host_pct:-unknown}%, keeping last ${MAX_AGE})"
  docker container prune -f --filter "until=${MAX_AGE}"
  docker image prune -af --filter "until=${MAX_AGE}"
  docker builder prune -af --filter "until=${MAX_AGE}"
fi
