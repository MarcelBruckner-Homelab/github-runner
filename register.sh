#!/usr/bin/env bash
# register.sh — add one new GitHub Actions self-hosted runner (DinD-isolated,
# capacity 1) to this host, using a Docker-in-Docker sidecar per runner.
#
# Usage:
#   ./register.sh --scope org  --org  <ORG_NAME>       --name <runner-name> --labels docker
#   ./register.sh --scope repo --repo <owner>/<repo>   --name <runner-name> --labels docker
#
#   The final runner name is auto-prefixed with this machine's hostname
#   (e.g. --name builder-01 on host "my-host" registers as
#   "my-host-builder-01"), so names stay unique across machines.
#
# Optional flags:
#   --pat-name <VAR>  name of the .env variable holding the PAT (default: GH_PAT)
#                      use this to pick between multiple stored PATs, one per org/owner
#   --token <PAT>     use this PAT directly instead of reading .env at all
#   --group <name>    runner group (org scope only, default: Default)
#   --ephemeral       run one job then de-register (fresh container next run)
#
# Requires a GitHub PAT in ./.env (see .env.example), one variable per org/owner
# you register against, e.g.:
#   GH_PAT=...                for the default org/owner
#   GH_PAT_MYORG=...          for another org/owner, via --pat-name GH_PAT_MYORG
# Each PAT needs:
#   org scope:  Organization permissions -> Self-hosted runners: Read and write
#   repo scope: Repository permissions   -> Administration: Read and write
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

scope=""
org=""
repo=""
name=""
labels=""
token=""
pat_name="GH_PAT"
group="Default"
ephemeral=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) scope="$2"; shift 2 ;;
    --org) org="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --labels) labels="$2"; shift 2 ;;
    --token) token="$2"; shift 2 ;;
    --pat-name) pat_name="$2"; shift 2 ;;
    --group) group="$2"; shift 2 ;;
    --ephemeral) ephemeral="true"; shift 1 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$scope" ]] && { echo "Missing --scope org|repo" >&2; exit 1; }
[[ -z "$name" ]] && { echo "Missing --name <runner-name>" >&2; exit 1; }
[[ -z "$labels" ]] && { echo "Missing --labels a,b,c" >&2; exit 1; }
[[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "--name must contain only letters, digits, - and _" >&2; exit 1; }

hostname_slug="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
[[ -n "$hostname_slug" ]] && name="${hostname_slug}-${name}"

case "$scope" in
  org)  [[ -z "$org" ]] && { echo "Missing --org <ORG_NAME> for --scope org" >&2; exit 1; } ;;
  repo) [[ -z "$repo" ]] && { echo "Missing --repo <owner>/<repo> for --scope repo" >&2; exit 1; } ;;
  *) echo "--scope must be 'org' or 'repo'" >&2; exit 1 ;;
esac

[[ "$pat_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "--pat-name must be a valid env var name" >&2; exit 1; }

if [[ -z "$token" ]]; then
  [[ -f .env ]] || { echo "No $SCRIPT_DIR/.env found. Copy .env.example and set $pat_name, or pass --token." >&2; exit 1; }
  token="$(grep -E "^${pat_name}=" .env | head -n1 | cut -d= -f2-)"
fi
[[ -z "$token" ]] && { echo "No PAT found for '$pat_name' in $SCRIPT_DIR/.env (or pass --token directly). See .env.example." >&2; exit 1; }

runner_dir="runners/$name"
[[ -e "$runner_dir" ]] && { echo "runners/$name already exists — pick a different --name, or run ./deregister.sh $name first." >&2; exit 1; }

if [[ "$scope" == "org" ]]; then
  check_url="https://api.github.com/orgs/${org}/actions/runners"
else
  check_url="https://api.github.com/repos/${repo}/actions/runners"
fi
echo "==> Checking PAT against $check_url"
http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" "$check_url")
[[ "$http_status" == "200" ]] || { echo "GitHub API check failed (HTTP $http_status) — verify the PAT and its permissions." >&2; exit 1; }

echo "==> Creating $runner_dir"
mkdir -p "$runner_dir/data"
cp runner-template/docker-compose.yaml "$runner_dir/docker-compose.yaml"

repo_url=""
[[ "$scope" == "repo" ]] && repo_url="https://github.com/${repo}"

cat > "$runner_dir/.env" <<EOF
ACCESS_TOKEN=${token}
RUNNER_SCOPE=${scope}
ORG_NAME=${org}
REPO_URL=${repo_url}
RUNNER_NAME=${name}
RUNNER_GROUP=${group}
LABELS=${labels}
# myoung34/github-runner checks "-n \$EPHEMERAL" (set to anything = true), not
# its value — must be left empty rather than "false" to mean non-ephemeral.
EPHEMERAL=${ephemeral}
EOF
chmod 600 "$runner_dir/.env"

echo "==> Ensuring shared network + registry mirror are up"
docker compose up -d

echo "==> Starting dind-${name} / runner-${name}"
docker compose -f "$runner_dir/docker-compose.yaml" --env-file "$runner_dir/.env" up -d

cat <<EOF

Runner '${name}' starting. Check registration with:
  docker compose -f $runner_dir/docker-compose.yaml --env-file $runner_dir/.env logs -f runner

Remove it later with:
  ./deregister.sh ${name}
EOF
