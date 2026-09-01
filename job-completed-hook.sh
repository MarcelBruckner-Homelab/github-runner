#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED — the runner binary invokes this after
# every job (regardless of outcome), before going back to "Listening for
# Jobs". Forcibly clears every container and unused network on this
# runner's own dind sidecar via the same DOCKER_HOST the runner itself
# uses, so the next job never inherits one left behind by this one.
#
# Why this exists: dind is shared across every job scheduled onto this
# runner slot — it is not recreated between jobs, even with --ephemeral
# (see DEPLOYMENT.md "Ephemeral vs persistent runners"). A job that fails
# before its own `docker compose down`, or whose down step itself fails
# silently (observed live: Compose reporting a container "Removed" when
# `docker stop` had actually errored and left it running), leaves
# containers that block the next job on the same port or name — including
# a *different* job/workflow scheduled onto this same slot later. This
# hook makes that structurally impossible: whatever the next job needs,
# it starts from a daemon with zero containers on it, independent of
# whether any workflow's own cleanup step ran or worked.
#
# Deliberately does NOT touch images or build cache (no `system prune`)
# — only running/stopped containers and unused networks are cleared, so
# builds stay warm across jobs.
set -uo pipefail   # not -e: best-effort cleanup must never fail the runner

echo "==> job-completed-hook: clearing dind (DOCKER_HOST=${DOCKER_HOST:-unset}) before next job"

containers="$(docker ps -aq 2>/dev/null || true)"
if [[ -n "$containers" ]]; then
  # shellcheck disable=SC2086
  docker rm -f $containers || true
fi

docker network prune -f >/dev/null 2>&1 || true

echo "==> job-completed-hook: done"
exit 0
