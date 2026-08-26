# Deployment & operations

Detailed reference for the `github-runner` stack. If you just want to get a
runner going, start with the [README](README.md) — this document is the
deep dive.

## Contents

- [PATs and `.env`](#pats-and-env)
- [`register.sh` reference](#registersh-reference)
- [Labels: one is enough](#labels-one-is-enough)
- [Ephemeral vs persistent runners (the EPHEMERAL gotcha)](#ephemeral-vs-persistent-runners-the-ephemeral-gotcha)
- [Disk management](#disk-management)
- [Running on macOS](#running-on-macos)
- [Why Docker instead of a bare-metal install](#why-docker-instead-of-a-bare-metal-install)
- [Why no job-container DNS workaround (unlike Gitea)](#why-no-job-container-dns-workaround-unlike-gitea)

## PATs and `.env`

Each PAT is a fine-grained GitHub token, scoped to one org/owner:

- org-scoped runners: **Organization permissions → Self-hosted runners: Read and write**
- repo-scoped runners: **Repository permissions → Administration: Read and write**

Since a fine-grained PAT only ever covers one owner, registering against
multiple orgs/owners means storing multiple variables in `.env` — one per
owner — and telling `register.sh` which one to use with `--pat-name`:

```bash
GH_PAT=...                 # default org/owner
GH_PAT_MYORG=...           # a second org/owner
```

`.env` (and everything under `runners/`) is gitignored — the tokens never get
committed.

For the read-only token used by the
[fallback selector action](README.md#never-get-stuck-on-an-offline-runner)
(`RUNNER_CHECK_TOKEN`), see the
[action's README](https://github.com/MarcelBruckner-Homelab/self-hosted-runner-selector#token).

## `register.sh` reference

```bash
./register.sh --scope org  --org  <ORG_NAME>       --name <runner-name> --labels docker
./register.sh --scope repo --repo <owner>/<repo>   --name <runner-name> --labels docker
```

| Flag | Meaning |
|------|---------|
| `--scope org\|repo` | Register against an organization or a single repository. |
| `--org <ORG_NAME>` | Org name (org scope). |
| `--repo <owner>/<repo>` | Repository (repo scope). |
| `--name <name>` | Runner name; auto-prefixed with the machine's hostname. |
| `--labels a,b,c` | Custom labels (see below — one is usually enough). |
| `--pat-name <VAR>` | `.env` variable holding the PAT (default `GH_PAT`). |
| `--group <name>` | Runner group, org scope only (default `Default`). |
| `--ephemeral` | Run one job then de-register (see the gotcha below). |
| `--token <PAT>` | Use this PAT directly instead of reading `.env`. |

The final runner name is auto-prefixed with the machine's hostname (e.g.
`--name builder-01` on host `my-host` registers as `my-host-builder-01`), so
the same `--name` can be reused safely across machines.

The script checks the PAT against the GitHub API, then creates
`runners/<name>/` (a compose file + env file, both gitignored — the env file
holds the token) and brings up the `dind-<name>` + `runner-<name>` pair. Check
registration with:

```bash
docker compose -f runners/<name>/docker-compose.yaml --env-file runners/<name>/.env logs -f runner
```

Remove a runner with `./deregister.sh <name>` — it stops the pair (the runner
de-registers from GitHub on graceful shutdown) and deletes `runners/<name>/`.

## Labels: one is enough

GitHub auto-adds `self-hosted`, the OS (`Linux`), and the arch (`X64`) to every
runner. Since every runner in this stack is built identically (same image, same
DinD sidecar), one custom label — `docker` — is all you need to target it;
extra labels like `linux`/`builder` add no selectivity over the auto labels.

## Ephemeral vs persistent runners (the EPHEMERAL gotcha)

Pass `--ephemeral` to `register.sh` for a runner that de-registers after one
job — worth it for anything that might see untrusted/fork-PR code. It
self-sustains via `restart: unless-stopped`: the runner process exits after a
job, the container restarts, and the entrypoint re-registers fresh with
`--replace`. Note the `dind` sidecar is *not* recycled on that cycle — only the
runner container restarts — so a job's Docker layers can still be visible to
the next job on the same daemon even with `--ephemeral`.

**The gotcha:** `myoung34/github-runner`'s entrypoint checks `-n "$EPHEMERAL"`
— i.e. *is the variable set to anything* — not its value. So `EPHEMERAL=false`
(a non-empty string) still passes `--ephemeral`, silently self-destructing
every runner after its first job. A **persistent** runner needs the variable
left **empty**, which is why the generated `.env` and the compose template's
`${EPHEMERAL:-}` default both leave it blank rather than `false`. (`${VAR:-default}`
substitutes the default for an *empty* value too, not just an unset one — so a
stale per-runner compose file copied before this was fixed must be refreshed
from the template, not just have its `.env` edited.)

## Disk management

Each dind sidecar keeps its own image cache; the shared `registry-mirror`
service (Docker Hub pull-through cache) means only the first runner to pull an
image hits the internet. Prune per-runner caches on a schedule — on Linux use
cron via `install-cron.sh`, on macOS use launchd via `install-launchd.sh` (see
[Running on macOS](#running-on-macos)). Either installs the hourly job:

```
0 * * * * /path/to/github-runner/prune-dind.sh >> /var/log/prune-github-runner.log 2>&1
```

`prune-dind.sh` discovers all `github-dind-*` containers dynamically, so it
doesn't need updating as runners are added/removed. The registry-mirror volume
is never pruned — it's the long-lived shared cache.

By default `prune-dind.sh` also runs a host-level `docker system prune -af`
after the sidecars — fine on a dedicated runner host, but on a machine you also
develop on it wipes images/build cache/networks from unrelated projects. Pass
`--dind-only` to prune just the `github-dind-*` sidecar caches and skip the
host-level prune. `install-launchd.sh` uses `--dind-only` for exactly this
reason.

## Running on macOS

Works unmodified via Docker Desktop — `docker:27-dind` (privileged) and
`myoung34/github-runner` both run fine inside Docker Desktop's Linux VM, and
`register.sh` only needs `bash`/`curl`, both present on macOS. This repo is
fully standalone — clone it directly on the Mac; nothing else is needed.

```bash
brew install --cask docker   # if Docker Desktop isn't already installed
git clone https://github.com/MarcelBruckner-Homelab/github-runner.git
cd github-runner
cp .env.example .env && vim .env   # set your PAT(s)
./register.sh --scope org --org <ORG_NAME> --name <runner-name> --labels docker
```

**Hourly prune on macOS — use launchd, not cron.** Modern macOS (Ventura+)
restricts background `cron` execution unless Terminal (or whatever app runs the
script) is granted **Full Disk Access** in System Settings → Privacy &
Security, so `install-cron.sh` will silently not run. Use the launchd installer
instead:

```bash
./install-launchd.sh            # install + load the hourly agent
./install-launchd.sh --remove   # unload + delete it
```

It installs a per-user LaunchAgent (`com.github-runner.prune-dind`,
`~/Library/LaunchAgents/`) that runs `prune-dind.sh --dind-only` hourly,
logging to `~/Library/Logs/prune-github-runner.log`. No root, no Full Disk
Access needed. Because launchd gives jobs a minimal `PATH`, the installer bakes
Docker Desktop's `docker` location into the agent's `PATH`. Test a run
immediately with:

```bash
launchctl kickstart -p gui/$(id -u)/com.github-runner.prune-dind
```

## Why Docker instead of a bare-metal install

GitHub itself only ships a tarball + `config.sh`/`run.sh`, not a container
image. This setup uses the `myoung34/github-runner` image, which wraps that
same tarball and additionally exchanges the long-lived PAT for a short-lived
registration token automatically (org tokens expire in ~1h). Chosen over a
bare-metal systemd install because:

- a uniform compose lifecycle and a shared registry-mirror/prune pattern across
  all runners
- it avoids putting the runner user in the host's `docker` group — DinD sidecar
  isolation means the runner container never touches the host socket

## Why no job-container DNS workaround (unlike Gitea)

Gitea's `act_runner` spawns a *separate* container per job with its own Docker
client, which is why that setup needs `network: ""` + `host.docker.internal`
gymnastics to reach the DinD daemon. GitHub's own runner binary runs job steps
as its own process and talks to Docker directly — `DOCKER_HOST=tcp://dind:2375`
on the runner container is the only wiring needed; service containers get
GitHub's normal per-job bridge network and DNS with no extra config.
