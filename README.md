# AffiNE self-host + MCP

Self-hosted [AffiNE](https://affine.pro) with the community
[`affine-mcp-server`](https://github.com/DAWNCR0W/affine-mcp-server) (pinned as a git
submodule) exposed over **HTTP**, so MCP clients (Claude Code, etc.) can drive AffiNE.

## Quick start (fresh machine)

Requires Docker (with Compose v2), `git`, `openssl`, `curl`.

```bash
git clone --recurse-submodules <this-repo-url> affine
cd affine
./bootstrap.sh
```

`bootstrap.sh` will:

1. init the `affine-mcp-server` submodule (pinned to **v2.1.0**),
2. generate `.env` — random DB password + MCP bearer token — and prompt for the AffiNE account,
3. start AffiNE, wait for it, and ask you to create that account at `http://localhost:3010`,
4. build & start the MCP server and write `.mcp.json`.

Cloned without submodules? Run `git submodule update --init --recursive` first.

## Services & pinned versions

| Service     | URL / access                  | Pinned version            |
| ----------- | ----------------------------- | ------------------------- |
| AffiNE web  | http://localhost:3010         | affine `0.26.7`           |
| MCP (HTTP)  | http://localhost:3011/mcp     | affine-mcp-server `v2.1.0`|
| Postgres    | internal (named volume `affine_pgdata`) | pgvector `pg16`     |
| Redis       | internal (compose network)    | redis `8.8.0`             |

All container images are **digest-pinned** in `docker-compose.yml`; the MCP server is built
from the version-pinned submodule.

## Runtime: Docker or rootless Podman

Works under both `docker compose` and `podman compose`. Postgres uses a **named volume**
(not a host bind mount) on purpose: Postgres runs as an in-container non-root UID (999), which
Docker maps to host 999 but rootless Podman maps to a subuid — a shared host bind mount can't
satisfy both and Podman's entrypoint fails with `chown … Operation not permitted`. The named
volume is owned correctly by whichever runtime creates it.

Docker and Podman both bind host ports 3010/3011, so **only one runtime can run the stack at a
time**. To switch, stop the other first (e.g. `docker compose down`, then `podman compose up -d`).
Each runtime keeps its own independent `affine_pgdata` volume.

## MCP client config

`bootstrap.sh` writes `.mcp.json` from `.mcp.json.example` with the generated bearer token.
Any HTTP MCP client points at `http://localhost:3011/mcp` with header
`Authorization: Bearer <AFFINE_MCP_HTTP_TOKEN>` (see `.env`).

## Notes

- **Workspaces must be cloud (server-synced)** to be visible to MCP — local browser-only
  workspaces never reach the server. In the AffiNE UI, "Enable AFFiNE Cloud" on the workspace.
- **Secrets** (`.env`, `.mcp.json`) are gitignored. Never commit them.
- The MCP server defers email/password login until just after a session connects, so the very
  first tool call can briefly return empty before auth settles. For deterministic startup, set
  `AFFINE_API_TOKEN` in `.env` (token auth is not deferred).

## Backup & restore

Per the [official guidance](https://docs.affine.pro/self-host-affine/administer/backup-and-restore),
a backup is a logical `pg_dump` of Postgres plus the uploads and config. Two on-demand scripts
(no scheduler) handle this; both auto-detect Docker vs Podman.

```bash
./backup.sh              # full backup -> ~/.affine/backups/<timestamp>/
./backup.sh --keep 14    # also prune all but the newest 14 backups
```

Each backup folder contains `affine.backup` (custom-format DB dump), `storage.tar.gz` (uploads),
`config.tar.gz` + `env.backup` (config), and `manifest.txt`. The stack must be running.
Backups go to `~/.affine/backups` by default (override with `BACKUP_ROOT=/path ./backup.sh`) —
they hold a copy of `.env`, so keep them private and ideally copy them off-machine.

```bash
./restore.sh <timestamp>     # e.g. ./restore.sh 20260611-140600
```

Restore stops the stack, **safety-dumps the current DB first** (to `~/.affine/backups/pre-restore-*`),
recreates the Postgres volume, restores the dump, restores uploads/config (moving the current ones
aside as `*.before-restore.*`), and brings the stack back up. `env.backup` is **not** auto-applied.
It prompts before doing anything destructive (`FORCE=1` skips the prompt).

> Tip: take a fresh `./backup.sh` right before any upgrade or risky change.

## Migrate to another machine

The normal path is just backup → restore (both auto-detect Docker/Podman):

```bash
# On the OLD machine (stack running):
./backup.sh                                  # -> ~/.affine/backups/<ts>/

# Copy the whole ~/.affine/backups/<ts> folder to the NEW machine, then there:
git clone --recurse-submodules <repo-url> affine && cd affine
mkdir -p ~/.affine/backups && cp -r /path/to/<ts> ~/.affine/backups/
cp ~/.affine/backups/<ts>/env.backup .env    # reuse secrets + pairs with the restored private.key
ENGINE=podman ./restore.sh <ts>              # drop ENGINE= for Docker
# regenerate the MCP client config (token is already in .env):
sed -e "s|__MCP_PORT__|$(grep ^MCP_PORT= .env|cut -d= -f2)|g" \
    -e "s|__AFFINE_MCP_HTTP_TOKEN__|$(grep ^AFFINE_MCP_HTTP_TOKEN= .env|cut -d= -f2)|g" \
    .mcp.json.example > .mcp.json
```

The account, workspaces, docs and uploads come across in the dump + blobs; carrying `config`
(with `private.key`) keeps token/session signing consistent. On rootless Podman, first run
`loginctl enable-linger "$USER"` so the stack survives logout.

> One-time caveat: if a database was created under Docker (Postgres UID 999 → host 999) it can't
> be read by rootless Podman. Recover it once with a throwaway **Docker** Postgres over the old
> data dir (`docker run -e POSTGRES_HOST_AUTH_METHOD=trust -v <pgdata>:/var/lib/postgresql/data
> pgvector/pgvector:pg16`, then `pg_dump`) before restoring on the Podman machine.

## Bumping the MCP version

```bash
cd affine-mcp-server
git fetch --tags
git checkout <new-tag>
cd ..
git add affine-mcp-server
git commit -m "Bump affine-mcp-server to <new-tag>"
```

## Updating pinned images

Edit the `image:` digests in `docker-compose.yml`, then `docker compose pull && docker compose up -d`.
