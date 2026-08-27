# github-runner

[![Pairs with self-hosted-runner-selector](https://img.shields.io/badge/pairs_with-self--hosted--runner--selector-2088FF?logo=githubactions&logoColor=white)](https://github.com/MarcelBruckner-Homelab/self-hosted-runner-selector)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Self-hosted GitHub Actions runners with **per-runner Docker-in-Docker
isolation**, deployed via Docker Compose. Each runner gets its own Docker
daemon, so jobs can build and run containers without touching the host or
colliding with each other. Standalone (own network + registry mirror), runs on
**Linux and macOS**.

> 🔗 **Pairs with [`self-hosted-runner-selector`](https://github.com/MarcelBruckner-Homelab/self-hosted-runner-selector)** —
> a companion action that routes a workflow to this fleet when it's online and
> falls back to GitHub-hosted runners when it isn't, so jobs never queue against
> an offline runner. See [Never get stuck on an offline runner](#never-get-stuck-on-an-offline-runner).

> Deep detail, tuning, and design rationale live in **[DEPLOYMENT.md](DEPLOYMENT.md)**.

## How it works

Each runner = one `dind-<name>` + `runner-<name>` container pair, capacity 1.
**Concurrency comes from adding more runners, not raising capacity on one** —
each gets its own isolated Docker daemon, so concurrent jobs never collide on
ports or container names. A shared `registry-mirror` service caches image pulls
so only the first runner to pull an image hits the internet.

## Prerequisites

- **Docker** — Docker Engine (Linux) or Docker Desktop (macOS).
- **A fine-grained GitHub PAT** scoped to the org/owner you'll register against:
  - org-scoped runners: **Organization → Self-hosted runners: Read and write**
  - repo-scoped runners: **Repository → Administration: Read and write**

## Quick start

```bash
git clone https://github.com/MarcelBruckner-Homelab/github-runner.git
cd github-runner
cp .env.example .env
vim .env                 # set GH_PAT=<your token>

# register one runner against an org
./register.sh --scope org --org <ORG_NAME> --name builder-01 --labels docker
```

That's it — the runner registers and starts. Target it from a workflow with
its label:

```yaml
jobs:
  build:
    runs-on: [self-hosted, docker]
    steps:
      - uses: actions/checkout@v4
      - run: docker compose build
```

Confirm it came online:

```bash
docker compose -f runners/<name>/docker-compose.yaml --env-file runners/<name>/.env logs -f runner
```

## Never get stuck on an offline runner

A job that targets a self-hosted runner (`runs-on: [self-hosted, docker]`)
**queues for up to 24h** if no matching runner is online — it does not fail
over to a GitHub-hosted runner on its own. Pair this fleet with
**[self-hosted-runner-selector](https://github.com/MarcelBruckner-Homelab/self-hosted-runner-selector)**,
a small companion action that checks the runners API and hands back a `runs-on`
value: your self-hosted labels when a matching runner is online, a GitHub-hosted
fallback when none are. One tiny `choose-runner` job runs it, then every real
job auto-configures its own `runs-on` — no duplicated jobs, no per-runner gates.

```yaml
jobs:
  choose-runner:
    runs-on: ubuntu-latest
    outputs:
      runner: ${{ steps.select.outputs.runner }}
    steps:
      - id: select
        uses: MarcelBruckner-Homelab/self-hosted-runner-selector@v1
        with:
          org: <ORG_NAME>
          primary-labels: self-hosted,docker
          fallback-labels: ubuntu-latest
          token: ${{ secrets.RUNNER_CHECK_TOKEN }}

  build:
    needs: choose-runner
    runs-on: ${{ fromJson(needs.choose-runner.outputs.runner) }}
    steps:
      - uses: actions/checkout@v4
      - run: docker compose build
```

`RUNNER_CHECK_TOKEN` is a **read-only** PAT (**Self-hosted runners: Read-only**
for org runners, **Administration: Read-only** for repo runners). Full inputs,
outputs, and setup are in the
[action's README](https://github.com/MarcelBruckner-Homelab/self-hosted-runner-selector).

## Managing runners

**Add** a runner (run again with a new `--name` for each concurrent slot):

```bash
./register.sh --scope org  --org  <ORG_NAME>     --name builder-01 --labels docker
./register.sh --scope repo --repo <owner>/<repo> --name builder-01 --labels docker
```

Names are auto-prefixed with the machine's hostname (`builder-01` →
`my-host-builder-01`), so the same `--name` is reusable across machines.

**Remove** one (de-registers from GitHub on graceful shutdown, then confirms
via the API and force-removes it if the graceful step didn't finish in time):

```bash
./deregister.sh <name>
```

Safe to re-run, and works even if `runners/<name>` is already gone — pass
`--scope org|repo` plus `--org`/`--repo` explicitly and it'll still check
GitHub and clean up an orphaned entry for that name:

```bash
./deregister.sh <name> --scope org --org <ORG_NAME>
```

**Remove several at once** with `--pattern <regex>` — matches and
deregisters every local `runners/<name>` whose name matches, no
confirmation prompt:

```bash
./deregister.sh --pattern '^my-host-builder-'
```

Add `--scope org|repo` plus `--org`/`--repo` to *also* sweep GitHub for
matching runners with no local trace at all (orphans from another machine,
or already torn down here) and force-remove those too:

```bash
./deregister.sh --pattern '^my-host-builder-' --scope org --org <ORG_NAME>
```

Without `--scope`, pattern mode only ever touches local runners — it never
queries or removes anything on GitHub for names it has no local record of.

**Multiple orgs/owners:** a fine-grained PAT covers one owner, so store one
variable per owner in `.env` (`GH_PAT`, `GH_PAT_MYORG`, …) and pick it with
`--pat-name`:

```bash
./register.sh --scope repo --repo myorg/myrepo --name builder-01 --labels docker --pat-name GH_PAT_MYORG
```

The full flag reference (`--ephemeral`, `--group`, `--token`) and why one
`docker` label is enough are in [DEPLOYMENT.md](DEPLOYMENT.md).

## Keeping disk in check

Each runner's DinD daemon accumulates its own image cache. Install the hourly
prune once:

```bash
./install-cron.sh        # Linux  (cron)
./install-launchd.sh     # macOS  (launchd — cron is unreliable on modern macOS)
```

On a machine you also develop on it runs in `--dind-only` mode so it won't
prune unrelated projects. Details and caveats: [DEPLOYMENT.md](DEPLOYMENT.md#disk-management).

## Learn more

**[DEPLOYMENT.md](DEPLOYMENT.md)** — full `register.sh` reference, ephemeral
runners and the EPHEMERAL gotcha, disk-management internals, macOS/launchd
specifics, and the design rationale (why Docker over bare metal, why no DNS
workaround unlike Gitea).
