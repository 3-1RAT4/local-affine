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
