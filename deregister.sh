#!/usr/bin/env bash
# deregister.sh <runner-name> | --pattern <regex>
#                [--scope org|repo] [--org <ORG_NAME>] [--repo <owner>/<repo>]
#                [--pat-name <VAR>] [--token <PAT>]
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
# Pass --pattern <regex> instead of a name to deregister every matching
# runner in one go: every local runners/<name> whose name matches is
# stopped and removed, and — if --scope plus --org or --repo is also given
# — every GitHub-registered runner matching the pattern with no local trace
# at all is force-removed too. Runs immediately; no confirmation prompt.
#
# Requires a PAT in ./.env (same one register.sh uses) with write access:
#   org scope:  Organization permissions -> Self-hosted runners: Read and write
#   repo scope: Repository permissions   -> Administration: Read and write
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

name=""
pattern=""
scope=""
org=""
repo=""
pat_name="GH_PAT"
token=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern) pattern="$2"; shift 2 ;;
    --scope) scope="$2"; shift 2 ;;
    --org) org="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --pat-name) pat_name="$2"; shift 2 ;;
    --token) token="$2"; shift 2 ;;
    --*) echo "Unknown argument: $1" >&2; exit 1 ;;
    *)
      [[ -n "$name" ]] && { echo "Unexpected extra argument: $1" >&2; exit 1; }
      name="$1"; shift 1 ;;
  esac
done

usage="Usage: $0 <runner-name> | --pattern <regex> [--scope org|repo] [--org <ORG_NAME>] [--repo <owner>/<repo>] [--pat-name <VAR>] [--token <PAT>]"
[[ -n "$name" && -n "$pattern" ]] && { echo "Pass either <name> or --pattern, not both." >&2; exit 1; }
[[ -z "$name" && -z "$pattern" ]] && { echo "$usage" >&2; exit 1; }

# Deregisters one runner by name: stops it locally if runners/<1> exists,
# then verifies with GitHub and force-removes any lingering entry. Uses the
# script-level scope/org/repo/token as defaults, falling back to the
# runner's own recorded .env values when locally present and not overridden.
deregister_one() {
  local target="$1"
  local t_scope="$scope" t_org="$org" t_repo="$repo" t_token="$token"
  local runner_dir="runners/$target"

  if [[ -d "$runner_dir" ]]; then
    [[ -z "$t_scope" ]] && t_scope="$(grep -E '^RUNNER_SCOPE=' "$runner_dir/.env" | cut -d= -f2-)"
    [[ -z "$t_org" ]] && t_org="$(grep -E '^ORG_NAME=' "$runner_dir/.env" | cut -d= -f2-)"
    if [[ -z "$t_repo" ]]; then
      local repo_url
      repo_url="$(grep -E '^REPO_URL=' "$runner_dir/.env" | cut -d= -f2-)"
      t_repo="${repo_url#https://github.com/}"
    fi

    echo "==> Stopping runner-${target} (attempts self-deregister from GitHub) and dind-${target}"
    docker compose -f "$runner_dir/docker-compose.yaml" --env-file "$runner_dir/.env" down

    echo "==> Removing $runner_dir"
    rm -rf "$runner_dir"
  else
    echo "No local runners/$target — checking GitHub directly for an orphaned entry."
  fi

  if [[ -z "$t_scope" ]]; then
    echo "Could not determine --scope for '${target}' (no local runner dir to read it from) — pass --scope org|repo explicitly." >&2
    return 1
  fi
  case "$t_scope" in
    org)  [[ -z "$t_org" ]] && { echo "Missing --org <ORG_NAME> for --scope org" >&2; return 1; } ;;
    repo) [[ -z "$t_repo" ]] && { echo "Missing --repo <owner>/<repo> for --scope repo" >&2; return 1; } ;;
    *) echo "--scope must be 'org' or 'repo'" >&2; return 1 ;;
  esac

  if [[ -z "$t_token" ]]; then
    [[ -f .env ]] || { echo "No $SCRIPT_DIR/.env found. Copy .env.example and set $pat_name, or pass --token." >&2; return 1; }
    t_token="$(grep -E "^${pat_name}=" .env | head -n1 | cut -d= -f2-)"
  fi
  [[ -z "$t_token" ]] && { echo "No PAT found for '$pat_name' in $SCRIPT_DIR/.env (or pass --token directly). See .env.example." >&2; return 1; }

  local api_base
  if [[ "$t_scope" == "org" ]]; then
    api_base="https://api.github.com/orgs/${t_org}/actions/runners"
  else
    api_base="https://api.github.com/repos/${t_repo}/actions/runners"
  fi

  echo "==> Checking GitHub for a lingering '${target}' registration"
  local runner_id
  runner_id="$(curl -sf -H "Authorization: Bearer ${t_token}" -H "Accept: application/vnd.github+json" "${api_base}?per_page=100" \
    | python3 -c "
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if r['name'] == name:
        print(r['id'])
        break
" "$target")"

  if [[ -z "$runner_id" ]]; then
    echo "No lingering registration found for '${target}' — already clean."
    return 0
  fi

  echo "==> '${target}' is still registered on GitHub (id ${runner_id}) — the graceful self-deregister didn't complete. Removing via API."
  curl -sf -X DELETE -H "Authorization: Bearer ${t_token}" -H "Accept: application/vnd.github+json" "${api_base}/${runner_id}" \
    && echo "Removed." \
    || { echo "Failed to remove runner ${runner_id} via API." >&2; return 1; }
}

if [[ -n "$name" ]]; then
  deregister_one "$name"
  exit 0
fi

# --pattern mode: sweep local runners/ dirs, then (if --scope is given)
# also sweep GitHub for matches with no local trace at all.
targets=()
if [[ -d runners ]]; then
  while IFS= read -r dir; do
    n="$(basename "$dir")"
    [[ "$n" =~ $pattern ]] && targets+=("$n")
  done < <(find runners -mindepth 1 -maxdepth 1 -type d | sort)
fi

if [[ -n "$scope" ]]; then
  case "$scope" in
    org)  [[ -z "$org" ]] && { echo "Missing --org <ORG_NAME> for --scope org" >&2; exit 1; }
          api_base="https://api.github.com/orgs/${org}/actions/runners" ;;
    repo) [[ -z "$repo" ]] && { echo "Missing --repo <owner>/<repo> for --scope repo" >&2; exit 1; }
          api_base="https://api.github.com/repos/${repo}/actions/runners" ;;
    *) echo "--scope must be 'org' or 'repo'" >&2; exit 1 ;;
  esac

  if [[ -z "$token" ]]; then
    [[ -f .env ]] || { echo "No $SCRIPT_DIR/.env found. Copy .env.example and set $pat_name, or pass --token." >&2; exit 1; }
    token="$(grep -E "^${pat_name}=" .env | head -n1 | cut -d= -f2-)"
  fi
  [[ -z "$token" ]] && { echo "No PAT found for '$pat_name' in $SCRIPT_DIR/.env (or pass --token directly). See .env.example." >&2; exit 1; }

  remote_names="$(curl -sf -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" "${api_base}?per_page=100" \
    | python3 -c "
import json, re, sys
pattern = sys.argv[1]
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if re.search(pattern, r['name']):
        print(r['name'])
" "$pattern")"

  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    [[ " ${targets[*]:-} " =~ [[:space:]]${n}[[:space:]] ]] || targets+=("$n")
  done <<< "$remote_names"
fi

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "No runners matched pattern '${pattern}'."
  exit 0
fi

echo "Deregistering ${#targets[@]} runner(s) matching '${pattern}': ${targets[*]}"
echo

failures=0
for t in "${targets[@]}"; do
  echo "=== ${t} ==="
  deregister_one "$t" || failures=$((failures + 1))
  echo
done

[[ $failures -eq 0 ]] || { echo "${failures} runner(s) failed to deregister cleanly." >&2; exit 1; }
