# github-runner

Self-hosted GitHub Actions runners, one DinD-isolated slot per runner —
same pattern as `../gitea`'s Actions runners, but registered against
GitHub instead of Gitea. Independent stack: own network, own registry
mirror, no shared state with Gitea.

Each runner = one `dind-<name>` + `runner-<name>` container pair, capacity 1.
Concurrency comes from adding more runners, not raising capacity on one —
each gets its own isolated Docker daemon, so concurrent jobs never collide
on ports/container names.

## Setup

```
cp .env.example .env
vim .env   # set GH_PAT, plus one GH_PAT_<NAME> per additional org/owner
```

Each PAT is a fine-grained GitHub token, scoped to one org/owner:
- org-scoped runners: **Organization permissions → Self-hosted runners: Read and write**
- repo-scoped runners: **Repository permissions → Administration: Read and write**

Since a fine-grained PAT only ever covers one owner, registering against
multiple orgs/owners means storing multiple variables in `.env` — one per
owner — and telling `register.sh` which one to use with `--pat-name`:

```
GH_PAT=...                 # default org
GH_PAT_TRAUREISE=...       # Traureise
```

## Adding a runner

```
./register.sh --scope org  --org  <ORG_NAME>      --name builder-01   --labels linux,docker,builder
./register.sh --scope repo --repo <owner>/<repo>   --name builder-01   --labels linux,docker,builder
./register.sh --scope repo --repo Traureise/traureise --name traureise-01 --labels linux,docker,builder --pat-name GH_PAT_TRAUREISE
```

`--pat-name` defaults to `GH_PAT`; pass it whenever the target org/owner
needs a different stored token. This checks the PAT against the GitHub API,
then creates `runners/<name>/` (compose file + env file, both gitignored —
the env file holds the token) and starts the pair. Check registration:

```
docker compose -f runners/<name>/docker-compose.yaml --env-file runners/<name>/.env logs -f runner
```

Other optional flags: `--group <name>` (org runner group), `--ephemeral`
(one job then de-register), `--token <PAT>` (use a PAT directly instead of
reading `.env` at all). Run `register.sh` again with a new `--name` for
each additional runner.

## Removing a runner

```
./deregister.sh <name>
```

Stops the pair (the runner de-registers from GitHub on graceful shutdown)
and deletes `runners/<name>/`.

## Disk management

Each dind sidecar keeps its own image cache; the shared `registry-mirror`
service (Docker Hub pull-through cache) means only the first runner to pull
an image hits the internet. Prune per-runner caches on a cron:

```
0 * * * * /root/development/github-runner/prune-dind.sh >> /var/log/prune-github-runner.log 2>&1
```

`prune-dind.sh` discovers all `github-dind-*` containers dynamically, so it
doesn't need updating as runners are added/removed. The registry-mirror
volume is never pruned — it's the long-lived shared cache.

## Why Docker instead of a bare-metal install

GitHub itself only ships a tarball + `config.sh`/`run.sh`, not a container
image. This setup uses the `myoung34/github-runner` image, which wraps that
same tarball and additionally exchanges the long-lived PAT for a short-lived
registration token automatically (org tokens expire in ~1h). Chosen over a
bare-metal systemd install because:

- it matches the Gitea stack already running on this host (same compose
  lifecycle, same registry-mirror/prune pattern)
- it avoids putting the runner user in the host's `docker` group — DinD
  sidecar isolation means the runner container never touches the host socket

## Why no job-container DNS workaround (unlike Gitea)

Gitea's `act_runner` spawns a *separate* container per job with its own
Docker client, which is why that setup needs `network: ""` +
`host.docker.internal` gymnastics (see `../gitea/dind-proxmox-lxc.md`).
GitHub's own runner binary runs job steps as its own process and talks to
Docker directly — `DOCKER_HOST=tcp://dind:2375` on the runner container is
the only wiring needed; service containers get GitHub's normal per-job
bridge network and DNS with no extra config.
