#!/usr/bin/env bash
# deregister.sh <runner-name> [--scope org|repo] [--org <ORG_NAME>] [--repo <owner>/<repo>]
#                              [--pat-name <VAR>] [--token <PAT>]
#
# Stops and removes a runner + its dind sidecar, then confirms with the
# GitHub API that it's actually gone. The runner image deregisters itself
# from GitHub on graceful SIGTERM (`down`), but that can fail to complete in
# time (mid-job, a slow API call, a dead PAT) — leaving an orphaned "offline"
# entry behind in the runners list that GitHub never auto-removes. When that
# happens, this force-removes it via the API instead.
#
# Safe to re-run: if runners/<name> was already removed by a prior run (or
# never existed here — e.g. you're cleaning up from a different machine),
# pass --scope plus --org or --repo explicitly and this will still check
# GitHub and remove any orphaned entry for that name.
#
# Requires a PAT in ./.env (same one register.sh uses) with write access:
#   org scope:  Organization permissions -> Self-hosted runners: Read and write
#   repo scope: Repository permissions   -> Administration: Read and write
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

name="${1:-}"
[[ -z "$name" ]] && { echo "Usage: $0 <runner-name> [--scope org|repo] [--org <ORG_NAME>] [--repo <owner>/<repo>] [--pat-name <VAR>] [--token <PAT>]" >&2; exit 1; }
shift || true

scope=""
org=""
repo=""
pat_name="GH_PAT"
token=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) scope="$2"; shift 2 ;;
    --org) org="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --pat-name) pat_name="$2"; shift 2 ;;
    --token) token="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

runner_dir="runners/$name"

if [[ -d "$runner_dir" ]]; then
  # Fall back to the runner's own recorded scope/org/repo when not overridden.
  [[ -z "$scope" ]] && scope="$(grep -E '^RUNNER_SCOPE=' "$runner_dir/.env" | cut -d= -f2-)"
  [[ -z "$org" ]] && org="$(grep -E '^ORG_NAME=' "$runner_dir/.env" | cut -d= -f2-)"
  if [[ -z "$repo" ]]; then
    repo_url="$(grep -E '^REPO_URL=' "$runner_dir/.env" | cut -d= -f2-)"
    repo="${repo_url#https://github.com/}"
  fi

  echo "==> Stopping runner-${name} (attempts self-deregister from GitHub) and dind-${name}"
  docker compose -f "$runner_dir/docker-compose.yaml" --env-file "$runner_dir/.env" down

  echo "==> Removing $runner_dir"
  rm -rf "$runner_dir"
else
  echo "No local runners/$name — checking GitHub directly for an orphaned entry."
fi

[[ -z "$scope" ]] && { echo "Could not determine --scope (no local runner dir to read it from) — pass --scope org|repo explicitly." >&2; exit 1; }
case "$scope" in
  org)  [[ -z "$org" ]] && { echo "Missing --org <ORG_NAME> for --scope org" >&2; exit 1; } ;;
  repo) [[ -z "$repo" ]] && { echo "Missing --repo <owner>/<repo> for --scope repo" >&2; exit 1; } ;;
  *) echo "--scope must be 'org' or 'repo'" >&2; exit 1 ;;
esac

if [[ -z "$token" ]]; then
  [[ -f .env ]] || { echo "No $SCRIPT_DIR/.env found. Copy .env.example and set $pat_name, or pass --token." >&2; exit 1; }
  token="$(grep -E "^${pat_name}=" .env | head -n1 | cut -d= -f2-)"
fi
[[ -z "$token" ]] && { echo "No PAT found for '$pat_name' in $SCRIPT_DIR/.env (or pass --token directly). See .env.example." >&2; exit 1; }

if [[ "$scope" == "org" ]]; then
  api_base="https://api.github.com/orgs/${org}/actions/runners"
else
  api_base="https://api.github.com/repos/${repo}/actions/runners"
fi

echo "==> Checking GitHub for a lingering '${name}' registration"
runner_id="$(curl -sf -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" "${api_base}?per_page=100" \
  | python3 -c "
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if r['name'] == name:
        print(r['id'])
        break
" "$name")"

if [[ -z "$runner_id" ]]; then
  echo "No lingering registration found for '${name}' — already clean."
  exit 0
fi

echo "==> '${name}' is still registered on GitHub (id ${runner_id}) — the graceful self-deregister didn't complete. Removing via API."
curl -sf -X DELETE -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" "${api_base}/${runner_id}" \
  && echo "Removed." \
  || { echo "Failed to remove runner ${runner_id} via API." >&2; exit 1; }
