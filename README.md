# Home Server Provisioning

Incus-based provisioning for a personal Ubuntu Server 26.04 home server.

**Workloads:** Nextcloud AIO (on host via Docker), JupyterHub (Incus system
container), Ollama + OpenWebUI (Incus VM), persistent LaTeX workspace (Incus
VM), persistent agent sandboxes (Incus VMs with Claude Code / Codex / Pi).

The NVMe uses separate LVM filesystems for the host and Incus. This is a
deliberate availability boundary: a VM image build can fill the Incus
filesystem without preventing Caddy, Docker, or the host from writing to `/`.

## Start here

- **[`SETUP.md`](./SETUP.md)** — full architecture, disaster-recovery
  bootstrap path, day-to-day usage, troubleshooting, file layout reference.
- **[`compose/nextcloud-aio.compose.yaml`](./compose/nextcloud-aio.compose.yaml)** —
  Nextcloud AIO mastercontainer Compose file.
- **[`PROJECT_REVIEW.md`](./PROJECT_REVIEW.md)** — current static review,
  accepted tradeoffs, and residual verification limits.
- **[`config.env`](./config.env)** — tracked defaults (resource sizes,
  image names, GIT_REPOS_ROOT).
- **[`LICENSE`](./LICENSE)** — MIT License.
- **`config.env.local`** (you create it; gitignored) — private local values
  such as a private dotfiles repo URL or Jupyter Tailscale auth key. Sourced
  after `config.env` by every script, so it overrides.

## Quick verification

After cloning, sanity-check the cloud-init templates locally:

```bash
shellcheck -x scripts/*.sh
docker compose -f compose/nextcloud-aio.compose.yaml config
./scripts/validate-cloud-init.sh
```

All checks should pass.

## GitHub Publishing Notes

- `config.env` contains tracked defaults only. Keep real private values in
  `config.env.local`, which is ignored by Git.
- Documentation and tracked examples use placeholders rather than real
  usernames, hostnames, domains, IP addresses, repository URLs, or auth keys.
- Preserve legal attribution in `LICENSE`; do not copy its identity into
  operational examples where it is not needed.
- The fixed VM login `admin` / `admin` is intentionally host-private on the
  Incus bridge; do not expose VM SSH publicly.
- Licensed under the MIT License. See `LICENSE`.
