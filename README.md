# github-runner

Self-hosted GitHub Actions runners with **per-runner Docker-in-Docker
isolation**, deployed via Docker Compose. Each runner gets its own Docker
daemon, so jobs can build and run containers without touching the host or
colliding with each other. Standalone (own network + registry mirror), runs on
**Linux and macOS**.

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
over to a GitHub-hosted runner on its own. This repo ships a Marketplace
composite action, **Self-Hosted Runner Selector**, that decides at run time:
it checks the runners API and hands back a `runs-on` value — your self-hosted
labels when a matching runner is online, your fallback labels when none are.

Matching is by **label** (a runner must carry *all* of the `primary-labels`),
so it survives host-prefixed names, renames, and fleets spread across several
machines. The same label set it probes for is the one it emits as `runs-on`, so
availability and scheduling never drift apart.

```yaml
- id: select
  uses: MarcelBruckner-Homelab/github-runner@v1
  with:
    org: <ORG_NAME>                    # or: repository: owner/repo (defaults to current)
    primary-labels: self-hosted,docker # probed AND used as runs-on when available
    fallback-labels: ubuntu-latest     # runs-on when no primary is online
    token: ${{ secrets.RUNNER_CHECK_TOKEN }}
```

| Input | Default | Purpose |
|-------|---------|---------|
| `token` | — (required) | PAT that can read runner status (see [token scope](DEPLOYMENT.md#the-runner_check_token-read-only-pat)). |
| `primary-labels` | `self-hosted` | Comma-separated; a runner must carry **all** of them. Becomes `runs-on` when available. |
| `fallback-labels` | `ubuntu-latest` | Comma-separated; the `runs-on` used when no primary is online. |
| `primaries-required` | `1` | Choose the primary only when at least this many matching runners are online. |
| `repository` | current repo | `owner/repo` to query. Ignored when `org` is set. |
| `org` | `''` | Organization to query instead of a repository. |

Outputs: `runner` (a `fromJson`-ready `runs-on` array), `online`
(`"true"`/`"false"`), and `count` (matching online primaries). Anything that
goes wrong — missing token, API error, no match — resolves to the **fallback**,
so a job never queues against an offline runner.

### Wiring it into a workflow

**One job, dynamic `runs-on`** — the clean default when the steps are identical
on both runner types. Probe once, then feed `runner` into `runs-on`:

```yaml
jobs:
  choose-runner:
    runs-on: ubuntu-latest
    timeout-minutes: 2
    outputs:
      runner: ${{ steps.select.outputs.runner }}
    steps:
      - id: select
        uses: MarcelBruckner-Homelab/github-runner@v1
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

**Two mirror jobs** — when the self-hosted and hosted steps genuinely differ
(different tooling, images, or licensing). Gate each on the `online` boolean and
let downstream jobs proceed on whichever ran:

```yaml
jobs:
  choose-runner:
    runs-on: ubuntu-latest
    timeout-minutes: 2
    outputs:
      online: ${{ steps.select.outputs.online }}
    steps:
      - id: select
        uses: MarcelBruckner-Homelab/github-runner@v1
        with:
          org: <ORG_NAME>
          primary-labels: self-hosted,docker
          token: ${{ secrets.RUNNER_CHECK_TOKEN }}

  build-self-hosted:
    needs: choose-runner
    if: needs.choose-runner.outputs.online == 'true'
    runs-on: [self-hosted, docker]
    steps:
      - uses: actions/checkout@v4
      - run: docker compose build

  build-hosted:
    needs: choose-runner
    if: needs.choose-runner.outputs.online != 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker compose build

  publish:
    needs: [build-self-hosted, build-hosted]
    # Exactly one build job runs; proceed when that one succeeded.
    if: >-
      !cancelled() &&
      (needs.build-self-hosted.result == 'success' ||
       needs.build-hosted.result == 'success')
    runs-on: ubuntu-latest
    steps:
      - run: echo "one of the two build jobs succeeded"
```

**Targeting a specific machine or OS** is just a matter of labels: set
`primary-labels: self-hosted,macOS,unity` to require a Mac,
`self-hosted,Linux,docker` to require a Linux box, or `self-hosted,docker` to
accept any runner in the fleet.

The action needs a read-only PAT in `RUNNER_CHECK_TOKEN`; setup and the
Marketplace publishing steps for maintainers are in
[DEPLOYMENT.md](DEPLOYMENT.md#the-runner_check_token-read-only-pat).

> **Credits:** the label-array-as-`runs-on` output model is inspired by
> [`mikehardy/runner-fallback-action`](https://github.com/mikehardy/runner-fallback-action)
> (MIT). This action is an independent implementation tailored to this fleet
> (composite `gh`+`jq`, read-only token, `online`/`count` outputs for the
> two-mirror-job variant).

## Managing runners

**Add** a runner (run again with a new `--name` for each concurrent slot):

```bash
./register.sh --scope org  --org  <ORG_NAME>     --name builder-01 --labels docker
./register.sh --scope repo --repo <owner>/<repo> --name builder-01 --labels docker
```

Names are auto-prefixed with the machine's hostname (`builder-01` →
`my-host-builder-01`), so the same `--name` is reusable across machines.

**Remove** one (de-registers from GitHub on graceful shutdown):

```bash
./deregister.sh <name>
```

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
runners and the EPHEMERAL gotcha, the `RUNNER_CHECK_TOKEN` scope and Marketplace
publishing for the [runner selector action](#never-get-stuck-on-an-offline-runner),
disk-management internals, macOS/launchd specifics, and the design rationale
(why Docker over bare metal, why no DNS workaround unlike Gitea).
