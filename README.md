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
- **[`scripts/teaching-vm.sh`](./scripts/teaching-vm.sh)** — persistent teaching
  workspace with separate public/private repositories and personal TEXMF.
- **[`config.env`](./config.env)** — tracked defaults (resource sizes,
  image names, repository roots, and teaching-workspace inputs).
- **[`LICENSE`](./LICENSE)** — MIT License.
- **`config.env.local`** (you create it; gitignored) — local values such as the
  real dotfiles repo URL or a Jupyter Tailscale auth key. Launch and build
  scripts source it after `config.env`, so its values override the defaults.

## Quick verification

After cloning, sanity-check the cloud-init templates locally:

```bash
shellcheck -x scripts/*.sh systemd/incus-docker-forward
docker compose -f compose/nextcloud-aio.compose.yaml config
./scripts/validate-cloud-init.sh
bash -n scripts/*.sh
```

All checks should pass.

On a host that runs both Docker and Incus, install the persistent bridge
forwarding integration once after installing those services:

```bash
sudo ./scripts/install-incus-docker-forwarding.sh
```

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
