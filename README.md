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
runners and the EPHEMERAL gotcha, disk-management internals, macOS/launchd
specifics, and the design rationale (why Docker over bare metal, why no DNS
workaround unlike Gitea).
