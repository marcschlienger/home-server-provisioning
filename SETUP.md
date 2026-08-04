# Home Server — Setup & Rebuild Reference

A single document covering the complete architecture, install order, and
day-to-day usage of this home server. **Treat this as the disaster-recovery
runbook**: following it on bare hardware should reproduce the working system.

---

## 1. Architecture Summary

A general-purpose Ubuntu Server hosting both user data and virtualization. One
machine, many workloads, clean isolation where it matters (agents in VMs),
direct host execution where overhead would be wasted (Nextcloud).

### Hardware

| Component | Spec |
|---|---|
| CPU | AMD Ryzen 9 — 12 cores / 24 threads |
| RAM | 128 GB |
| GPU | AMD Radeon RX 580 (Polaris, 8 GB VRAM) — Vulkan |
| Storage | SSD/NVMe — ext4 currently (ZFS path documented but optional) |
| Network | Tailscale for host management + optional Jupyter; VMs use host-local Incus networking |

### Workloads at a glance

| Workload | Where | Why |
|---|---|---|
| **Nextcloud AIO** | Docker on the host | Already-working AIO setup; not worth a VM |
| **Caddy** | Host service | Reverse proxy for AIO + future web services |
| **Tailscale** | Host + optional Jupyter container | Management access; not installed in VMs |
| **JupyterHub (TLJH)** | Incus system container | Lightweight, native install |
| **Ollama + OpenWebUI** | Incus VM | VM needed for future GPU passthrough; reached by local IP/proxy |
| **LaTeX workspace (persistent)** | Incus VM | Teaching worksheets; reached via incus exec or host-local SSH |
| **Agent VMs (persistent)** | Incus VM | Per-task sandbox; reached via incus exec or host-local SSH; no Tailscale |
| **Nextcloud data** | `/data/ncdata` on the data SSD | AIO data directory via `NEXTCLOUD_DATADIR` |
| **Git repos** | Host filesystem configured by `GIT_REPOS_ROOT` | Bind-mounted into VMs |
| **Backups** | User's existing system | rclone+crypt + Borg → B2 / Hetzner / rsync.net |

### Architecture diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Ubuntu Server 26.04  (ext4)                                             │
│                                                                          │
│  ┌────────────┐   ┌─────────┐   ┌────────────┐   ┌────────────────┐      │
│  │ Tailscale  │   │  Caddy  │   │   Docker   │   │     Incus      │      │
│  │  (host)    │   │ (proxy) │   │            │   │ (VMs + LXCs)   │      │
│  └────────────┘   └────┬────┘   └──────┬─────┘   └───────┬────────┘      │
│                        │               │                 │               │
│                        │               ▼                 │               │
│                        │      ┌─────────────────┐        │               │
│                        └──────► Nextcloud AIO   │        │               │
│                               └─────────────────┘        │               │
│                                                          │               │
│   /data/ncdata  ───────── Nextcloud AIO data              │               │
│   GIT_REPOS_ROOT  ─────── bind-mounted via Incus ─────────┤               │
│       ├─ teaching-worksheets/                            │               │
│       ├─ project-foo/                                    │               │
│       └─ ...                                             │               │
│                                                          ▼               │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐       │
│   │ jupyter      │  │ ollama VM    │  │  latex-ws + agent-* VMs  │       │
│   │ (LXC, TLJH)  │  │ + OpenWebUI  │  │  (all persistent)        │       │
│   └──────────────┘  └──────────────┘  └──────────────────────────┘       │
└──────────────────────────────────────────────────────────────────────────┘
                                  │
                                  │  Tailscale(host) + Internet
                                  ▼
                ┌──────────────────────────────┐
                │  Old Nextcloud box (recycled)│
                │  → backup target             │
                │  → nextcloudcmd sync         │
                │  → rsync incremental         │
                │  → rclone(+crypt) + Borg →   │
                │     B2 / Hetzner / rsync.net │
                └──────────────────────────────┘
```

---

## 2. Bootstrap from Scratch — Disaster Recovery Path

This is the order to follow on fresh hardware to rebuild the working system.

### 2.1 Install Ubuntu Server 26.04

- Download the **Server** ISO (not Desktop) from ubuntu.com
- During install:
  - Filesystem: ext4 (current setup) — or ZFS if you choose to reinstall
    (root-on-ZFS is the installer's "advanced features" option; lets you
    later add `sanoid`/`syncoid` replication as a VM-level backup tier)
  - Set up an SSH-enabled admin user (this is your daily-driver account)
  - Enable OpenSSH server
- After first boot:
  ```bash
  sudo apt update && sudo apt full-upgrade -y
  sudo apt install -y neovim git curl wget htop tmux zsh python3-yaml
  # python3-yaml is needed by ./scripts/validate-cloud-init.sh
  chsh -s $(which zsh)        # optional, switch to zsh
  ```

### 2.2 Install Tailscale (on the host)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh        # --ssh enables Tailscale SSH for this host
```

Sign in via the URL it prints. From now on you can SSH to this host over
Tailscale by hostname.

### 2.3 Install Incus

Ubuntu 26.04 ships Incus in the main repos:

```bash
sudo apt install -y incus incus-extra
# incus-extra brings incus-benchmark, incus-migrate, lxd-to-incus, etc.
sudo adduser $USER incus-admin
# Log out and back in (or `newgrp incus-admin`) for group to take effect
incus admin init
```

For `incus admin init`, accept defaults unless you have specific needs:
- Storage pool: `default`, backend: `dir` (ext4-friendly) or `zfs` if available
- Network: yes, `incusbr0` with default subnet
- Trust password: leave blank (you're using local socket)
- MAAS, clustering: no

**Verify the `images:` remote is present** (it's an Incus default, so it
usually is). This is the remote that hosts the Ubuntu cloud image we'll
build from.

```bash
incus remote list                              # confirm `images` is in the list
incus image alias list images: | grep ubuntu/26.04
# Expected:  ubuntu/26.04/cloud  <fingerprint>  …
```

If you don't see `ubuntu/26.04/cloud` in the alias list, the image hasn't
made it onto images.linuxcontainers.org yet for that release. Two fallbacks:
- Use `images:ubuntu/24.04/cloud` (set `UBUNTU_REMOTE` in `config.env`)
- Or use the daily build: `images:ubuntu/26.04/cloud/amd64`

Optional pre-fetch so the first build doesn't pause to download (~500–700 MB):

```bash
incus image copy images:ubuntu/26.04/cloud local: --alias ubuntu-2604-cloud
# Not strictly required — build-images.sh fetches on demand.
```

### 2.4 Install Docker (for Nextcloud AIO)

Use Docker's official apt repository, not the convenience script.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
# Log out and back in for group to take effect
```

### 2.5 Install Caddy (reverse proxy)

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
```

The package installs a sample `/etc/caddy/Caddyfile`. Replace the whole file
with this minimal Caddyfile for Nextcloud AIO and OpenWebUI.

Replace the domains, and replace `<OLLAMA_VM_IP>` with the Incus bridge IP
from `incus list ollama -c4`. If you later recreate the Ollama VM, re-run
that command, update the Caddyfile if the IP changed, and reload Caddy.

```caddyfile
cloud.yourdomain.tld {
    reverse_proxy 127.0.0.1:11000
}

ai.yourdomain.tld {
    reverse_proxy <OLLAMA_VM_IP>:3000
}
```

Then format, validate, and reload Caddy:

```bash
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Caddy auto-fetches TLS certificates. Make sure both DNS names point to this
host and that ports 80/443 are reachable from the internet.

OpenWebUI has its own login flow; the first account created in the web UI
becomes the admin account. Do **not** expose Ollama's raw `11434` API publicly
unless you add separate authentication in front of it.

JupyterHub is intentionally **not** included in the public Caddy config. If
`JUPYTER_TS_AUTHKEY` is set, use its Tailscale name (`http://jupyter/` by
default) from a Tailscale-connected device.

### 2.6 Configure the host git workspace directory

`GIT_REPOS_ROOT` is the host-side parent directory for repos when you pass a
bare name to `--git`. Set it in `config.env` to wherever your SSD storage is
mounted, for example:

```bash
GIT_REPOS_ROOT="/mnt/ssd/git"
sudo mkdir -p "$GIT_REPOS_ROOT"
sudo chown $USER:$USER "$GIT_REPOS_ROOT"
```

This is where you clone repos from GitHub / GitLab / Codeberg using your own
SSH credentials. They get bind-mounted into VMs read-write.

You can also bypass `GIT_REPOS_ROOT` for a single VM by passing an absolute
host path:

```bash
./scripts/new-agent-vm.sh refactor-foo --git /mnt/other-ssd/repos/project-foo
```

### 2.7 Bring up Nextcloud AIO

Follow the official AIO docs (`https://github.com/nextcloud/all-in-one`).
The Compose file in this repo follows the official AIO Compose example, with
Caddy as the public-facing TLS terminator and `/data/ncdata` as the Nextcloud
data directory.

Before first AIO startup, mount the data SSD at `/data` and confirm it is
mounted. Do not start AIO while `/data` is missing, otherwise `/data/ncdata`
could be created on the root filesystem by accident.

```bash
findmnt /data
sudo mkdir -p /data/ncdata
docker compose -f compose/nextcloud-aio.compose.yaml up -d
```

The ownership is intentional: `/data/ncdata` is the host-side data directory,
and AIO bind-mounts that same directory into the Nextcloud container as
`/mnt/ncdata`. The Nextcloud container accesses it as UID `33` (`www-data`),
and the official AIO docs use GID `0`. On a typical Linux host the directory
should therefore show up as `www-data:root` / `750` after AIO has initialized
the instance. Do not chown the whole `/data` mount; AIO should set up
`/data/ncdata` itself during the initial installation.

After AIO has completed the initial setup, verify the host-side data directory:

```bash
sudo stat -c '%U:%G %a %n' /data/ncdata
```

If migrated files are copied into the data directory later, or if files are
edited manually on disk, re-apply AIO's expected permissions. These commands run
inside the container but operate on the same host files under `/data/ncdata`
because `/mnt/ncdata` is the bind mount:

```bash
sudo docker exec nextcloud-aio-nextcloud chown -R 33:0 /mnt/ncdata/
sudo docker exec nextcloud-aio-nextcloud chmod -R 750 /mnt/ncdata/
sudo docker exec --user www-data -it nextcloud-aio-nextcloud php occ files:scan --all
```

For network filesystems that do not preserve normal Unix ownership, do not use
ad-hoc host-side permissions. Mount them with ownership/mode options compatible
with AIO instead, for example `uid=33,gid=0,file_mode=0770,dir_mode=0770` for
CIFS/SMB.

Then open `https://<host>:8080` (admin UI), complete the setup, point your
domain at the box, and Caddy will terminate TLS on the public side.

After the Nextcloud container is running, fix the common admin warning about
the missing default phone region. The value is an ISO 3166-1 alpha-2 country
code; use `DE` for Germany, or replace it with the country code that matches
the instance's users:

```bash
sudo docker exec --user www-data nextcloud-aio-nextcloud php occ config:system:set default_phone_region --value="DE"
```

`NEXTCLOUD_DATADIR` is set to `/data/ncdata` in the Compose file. Set this only
before the initial AIO installation; do not change it afterwards unless you are
following Nextcloud AIO's migration procedure.

After setup, hook up your existing `nextcloudcmd` sync workflow on the
backup box pointed at the new instance URL.

### 2.8 Get this provisioning repo onto the server

This directory (cloud-init/, scripts/, config.env, SETUP.md) is
the source of truth for everything below. Put it on the freshly-installed
server by whichever path you prefer:

```bash
# Option A — clone from your git server (Codeberg / GitHub / GitLab / private):
cd ~/
git clone <your-URL-for-this-repo> incus-provisioning
cd incus-provisioning

# Option B — rsync from your workstation if you keep it locally:
rsync -av ~/Documents/1-projects/incus/ user@server:~/incus-provisioning/
```

The point is just "make these files available on the server." Git is the
clean path; rsync works fine if you don't want to publish this anywhere.

### 2.9 Configure `config.env` and `config.env.local`

There are **two** config files; both get sourced by every script (`.local`
second, so it overrides). The split exists so private local values never get
tracked.

**`config.env`** — committed to git. Edit it for shared defaults (resource
sizes, image names, and the GIT_REPOS_ROOT path).

**`config.env.local`** — gitignored. This is where private local values go.
Create it on the new host if needed:

```bash
cat > config.env.local <<'EOF'
# Your real dotfiles repo (overrides the placeholder in config.env).
DOTFILES_REPO="git@github.com:YOUR_USER/dotfiles.git"

# Optional: put JupyterHub on your tailnet instead of exposing it publicly.
# Generate a reusable, pre-authorized key in the Tailscale admin console.
JUPYTER_TS_AUTHKEY="tskey-auth-REPLACE-WITH-REAL-KEY"
EOF
chmod 600 config.env.local
```

Notes:
- `DOTFILES_INSTALL_CMD` default is `stow .` — change in `.local` only if
  your repo uses a different layout. Must be a one-line command without
  single quotes or newlines (the launch scripts reject those).
- The unedited placeholder URL `https://github.com/YOUR_USERNAME/dotfiles`
  is treated as "no dotfiles" by the optional-dotfiles workloads
  (Ollama). LaTeX and agent VMs require a real URL and will refuse to
  launch with the placeholder.
- VM SSH uses the fixed local login `admin` / `admin`. This is only for the
  host-private Incus bridge; do not expose VM SSH beyond that.
- The fixed VM SSH password is rendered into Incus cloud-init user-data at
  launch time, so treat this repository as local machine configuration.
- `JUPYTER_TS_AUTHKEY` is only used by the Jupyter container. VMs still do
  not install or use Tailscale. If set, it must be a reusable auth key that
  starts with `tskey-auth-`.

### 2.10 Build the base Incus images

```bash
./scripts/build-images.sh
```

Expected timing: base ~10 min, latex ~30-40 min (texlive-full),
agents ~5 min. ~50 min total wall-clock for first run.

Subsequent rebuilds of one image only:
```bash
./scripts/build-images.sh --only base
./scripts/build-images.sh --only latex
./scripts/build-images.sh --only agents
```

### 2.11 VM login

The fixed VM login is:

```bash
username: admin
password: admin
```

The VMs are always reachable from the host with `incus exec`. You can also SSH
from the host only:

```bash
ssh admin@<vm-incusbr0-ip>
```

The Incus bridge IP is host-private and not reachable from your LAN or the
internet. Direct entry uses the same VM user:

```bash
incus exec <vm-name> -- su - admin
```

Passwordless SSH is not configured by these scripts anymore. If you later want
key-based login, add your public key manually to
`/home/admin/.ssh/authorized_keys` inside the VM.

### 2.12 Launch the persistent workloads

**LaTeX workspace** (teaching worksheets):
```bash
./scripts/new-latex-vm.sh latex-ws --git teaching-worksheets
# Script waits for cloud-init then drops you into a shell. Re-enter later
# with the same command (no --git needed; the mount is already attached).
```

**JupyterHub** (small group / personal):
```bash
./scripts/new-jupyter-container.sh marc jupyter
# wait ~10 min, then visit http://jupyter/ from a Tailscale-connected device
# if JUPYTER_TS_AUTHKEY is set. Otherwise visit http://<container-ip>/ locally.
```

**Ollama + OpenWebUI**:
```bash
./scripts/new-ollama-vm.sh ollama
# wait ~5-10 min, then visit http://<vm-ip>:3000
incus exec ollama -- ollama pull llama3.1:8b
```

### 2.13 Verify host and VM connectivity

From your workstation:
```bash
tailscale status
ssh <admin-user>@<server-tailscale-hostname>
```

The Jupyter container joins the tailnet only if `JUPYTER_TS_AUTHKEY` is set;
then visit `http://jupyter/` from a Tailscale-connected device. Guest VMs do
not join the tailnet. Reach them from the host via `incus exec`, or by SSH with
the fixed VM login:
```bash
ssh admin@<vm-incusbr0-ip>
```

---

## 3. Day-to-Day Usage

### 3.1 Working on a teaching worksheet (LaTeX VM)

```bash
# On the host:
source ./config.env
cd "$GIT_REPOS_ROOT/teaching-worksheets"
git pull                                      # sync from upstream

# Launch (first time only — supplies the --git mount) or re-enter the VM.
# The script handles both: creates if missing, starts if stopped, attaches
# if running. It always drops you into a shell at the end.
./scripts/new-latex-vm.sh latex-ws --git teaching-worksheets
# Later re-entries (mount is fixed at creation):
./scripts/new-latex-vm.sh latex-ws

# Inside the VM (tmux + nvim + agents):
# work on /home/admin/project (same files as $GIT_REPOS_ROOT/teaching-worksheets)
# Run agents:  claude / codex / pi
# Build PDFs:  latexmk -pdf main.tex

# Back on the host — review and push:
cd "$GIT_REPOS_ROOT/teaching-worksheets"
git status
git log --oneline -n 10
git push                                      # push with YOUR credentials
```

### 3.2 Running an agent on a project (persistent VM)

```bash
# Clone the project on the host (only first time):
source ./config.env
cd "$GIT_REPOS_ROOT"
git clone git@github.com:user/project-foo.git

# First run: creates the VM 'agent-refactor-foo' with the project mounted.
./scripts/new-agent-vm.sh refactor-foo --git project-foo
# (drops you into a shell inside the VM)

# Inside the VM: tmux, agents commit to a branch.
# Agent should commit to e.g. agent/refactor-foo branch — NOT main.

# Exit the shell (Ctrl-D). The VM KEEPS RUNNING in the background;
# partial work, agent auth state, shell history all persist.
# When you want to free the resources between sessions:
#   incus stop agent-refactor-foo

# Re-enter later — same command, no --git needed:
./scripts/new-agent-vm.sh refactor-foo

# On the host, review and push:
cd "$GIT_REPOS_ROOT/project-foo"
git log --all --oneline
git diff main..agent/refactor-foo
git checkout agent/refactor-foo               # or merge / cherry-pick
git push origin agent/refactor-foo            # or push main if merged

# When truly done with the task, free the VM:
incus stop  agent-refactor-foo
incus delete agent-refactor-foo
```

### 3.3 Talking to Ollama

- Open `https://ai.yourdomain.tld` for OpenWebUI once Caddy is configured
- Open `http://<ollama-vm-ip>:3000` from the host if you do not use Caddy
- CLI: `incus exec ollama -- ollama run llama3.1:8b`
- Pull more models: `incus exec ollama -- ollama pull mistral:7b`

From another machine, use SSH to the host for CLI access instead of exposing
the raw Ollama API:
```bash
ssh <admin-user>@<server-tailscale-hostname> \
  "incus exec ollama -- ollama run llama3.1:8b"
```

### 3.4 Inspecting VM state

```bash
incus list                                    # everything
incus info <name>                             # one VM, IPs, resources
incus exec <name> -- bash                     # quick root shell in VM
incus exec <name> -- su - admin               # user shell in VM
incus snapshot create <name> snap1            # manual snapshot
incus stop <name>                             # graceful stop
incus delete <name>                           # destroy the instance
```

---

## 4. Backups

The user's existing battle-tested backup system handles this — **do not
introduce new backup tools**. The system is:

| Tier | What | How |
|---|---|---|
| Sync (source of truth on backup box) | Nextcloud data | `nextcloudcmd` sync |
| Local incremental | Snapshot of synced data | User's rsync script |
| Off-site #1 (encrypted) | Same data | `rclone` with `crypt` backend |
| Off-site #2 (encrypted, different tool) | Same data | `borg` |
| Off-site providers (×3 for redundancy) | All of the above | Backblaze B2, Hetzner Storage Box, rsync.net |

**Extension for this new architecture:** point existing scripts at the new
sources:

- `nextcloudcmd` — update target URL to the AIO instance on this host
- `rsync` sources — add:
  - your configured `GIT_REPOS_ROOT` directory (belt-and-suspenders for
    unpushed agent commits)
  - `/data/ncdata` for Nextcloud data if your backup workflow does not already
    cover it through the existing Nextcloud sync path
  - Jupyter notebook directories (if not already in git)
- VM state / Ollama models / agent VM filesystems — **skip backup**.
  These are regenerable from cloud-init + `./build-images.sh`.

**Discipline rule for agents (important — VMs are NOT backed up):**

Anything an agent produces that you care about must live on the bind-mounted
project directory inside the VM. With the default VM user that path is
`/home/admin/project`. That path is backed by the host repo you supplied
with `--git`: either `$GIT_REPOS_ROOT/<repo>` for a bare name, or the absolute
host path you passed. The VM's filesystem itself is treated as disposable.
Specifically:

- Don't have agents write important output to `~/scratch`, `/tmp`, or anywhere
  outside `~/project` and expect it to survive
- If an agent makes commits but doesn't push, the commits live in the working
  tree on the host-side repo path — already on the host, already in your
  backup tree
- OpenWebUI chats live inside the Ollama VM's Docker volume. If chat history
  matters to you, add the Ollama VM's `openwebui` volume path to your rsync
  sources; otherwise treat as disposable.

### If you later install ZFS root

Add ZFS snapshots + `syncoid` as a **fast VM-level tier**, layered alongside
restic/borg (not replacing). Install:
```bash
sudo apt install sanoid
# configure /etc/sanoid/sanoid.conf to snapshot ZFS datasets on schedule
# use syncoid to replicate to backup box
```

---

## 5. Phase 1.5 — GPU Passthrough for Ollama

Deferred from initial setup. The RX 580 (Polaris) works with Vulkan on
Ubuntu 26.04 — verified — but the AMD "reset bug" can prevent the host
from re-attaching the card after VM shutdown.

### Prerequisites

1. **IOMMU enabled in BIOS** (AMD-Vi)
2. **GRUB kernel cmdline**:
   ```
   amd_iommu=on iommu=pt
   ```
   Edit `/etc/default/grub`, then `sudo update-grub && sudo reboot`
3. **Verify IOMMU groups** isolate the GPU:
   ```bash
   for d in /sys/kernel/iommu_groups/*/devices/*; do
     n=${d#*/iommu_groups/*}; n=${n%%/*}
     printf 'IOMMU Group %s ' "$n"
     lspci -nns "${d##*/}"
   done | grep -i radeon
   ```

### Install vendor-reset (for Polaris reset bug)

```bash
sudo apt install dkms build-essential
git clone https://github.com/gnif/vendor-reset.git
cd vendor-reset
sudo dkms install .
echo vendor-reset | sudo tee -a /etc/modules
sudo modprobe vendor-reset
```

### Bind GPU to vfio-pci

```bash
# Find GPU PCI IDs from lspci -nn (something like 1002:67df 1002:aaf0)
echo "options vfio-pci ids=1002:67df,1002:aaf0" \
  | sudo tee /etc/modprobe.d/vfio.conf
sudo update-initramfs -u && sudo reboot
```

### Pass GPU to the Ollama VM

```bash
incus stop ollama
incus config device add ollama gpu pci address=<bus:device.function>
incus start ollama
# Inside VM, install Mesa Vulkan drivers + Ollama's Vulkan backend
incus exec ollama -- apt install -y mesa-vulkan-drivers
# Restart ollama service — it auto-detects Vulkan
```

---

## 6. UID/GID Alignment for Bind Mounts

When you bind-mount a host repo into a VM with `--git`, the same files appear
under `/home/admin/project` inside the VM. For reads and writes to behave
naturally on both sides, **the host user that owns the directory and the VM user
(UID 1000) need to agree**.

### The common case (works out of the box)

If you installed Ubuntu Server normally and you are the first/only user, your
host account is UID 1000 and GID 1000 — the same as the VM user.
Files written by the agent inside the VM appear owned by you on the host,
and vice versa. Nothing to configure.

### The edge case (your host UID is not 1000)

If your host user has a different UID (multi-user system, you created the
admin account in a non-standard way, etc.):

- Files written by the agent appear under a different owner on the host
- You may not be able to read/edit them from the host without `sudo`
- The launch scripts print a `WARNING` when they detect this mismatch

**Fix options:**

1. **Easiest:** change the host directory's group ownership to match your
   actual UID/GID and accept that the VM username inside the VM is
   really your host UID:
   ```bash
   sudo chown -R $USER:$USER "$GIT_REPOS_ROOT/<repo>"
   ```
   Then make sure the VM user can write (group write bit, ACLs,
   or `chmod -R u+rwX,g+rwX "$GIT_REPOS_ROOT/<repo>"`).

2. **Cleaner long-term:** configure Incus `raw.idmap` on the VM to map your
   host UID/GID onto the VM's 1000:
   ```bash
   incus config set <vm-name> raw.idmap "both $(id -u) 1000"
   incus restart <vm-name>
   ```
   The VM user now reads/writes as your host UID, transparently.

### Sanity check

From inside the VM:
```bash
ls -ln /home/admin/project       # should show numeric UID 1000 (or your mapped UID)
touch /home/admin/project/.test  # should succeed
```
From the host:
```bash
ls -ln "$GIT_REPOS_ROOT/<repo>/.test"  # should show your UID, readable + removable
```

---

## 7. Troubleshooting

### Cloud-init failure during image build
```bash
# build-images.sh now dumps the tail of the cloud-init log on failure.
# Manually inspect a build VM if it's still around:
incus exec build-base-<timestamp> -- cat /var/log/cloud-init-output.log
```

### Incus VM has no network
- Check `incus network show incusbr0`
- Verify the host's firewall isn't blocking `incusbr0`
- `incus exec <name> -- ip a`

### Can't SSH into a VM
- Get the VM's host-private IP: `incus list <name> -c4`
- SSH from the HOST (incusbr0 isn't reachable from the LAN):
  `ssh admin@<that-ip>`
- If you need to reset the fixed VM user's password after launch:
  `incus exec <name> -- bash -c 'echo "admin:admin" | chpasswd && printf "PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n" > /etc/ssh/sshd_config.d/99-vm-password.conf && (systemctl reload ssh || systemctl restart ssh)'`

### Dotfiles didn't apply
- Verify `DOTFILES_REPO` is reachable (public, or token in URL)
- `incus exec <name> -- ls /home/admin/.dotfiles`
- `incus exec <name> -- tail /var/log/cloud-init-output.log`

### Agent VM has no project files
- Verify the source path exists on host: `ls "$GIT_REPOS_ROOT/<repo>"`, or
  check the absolute path you passed to `--git`
- Verify the device was added: `incus config device show <name>`
- Verify mount inside: `incus exec <name> -- ls /home/admin/project`

---

## 8. References

- Ubuntu Server: https://ubuntu.com/server
- Incus: https://linuxcontainers.org/incus/
- Tailscale: https://tailscale.com/kb/
- Caddy: https://caddyserver.com/docs/
- Nextcloud AIO: https://github.com/nextcloud/all-in-one
- TLJH (JupyterHub): https://tljh.jupyter.org/
- Ollama: https://github.com/ollama/ollama
- OpenWebUI: https://docs.openwebui.com/
- vendor-reset: https://github.com/gnif/vendor-reset
- restic / borg / rclone — user's existing toolchain

---

## 9. File Layout Reference

```
incus/
├── SETUP.md                          ← this file
├── README.md                         ← short pointer to SETUP.md
├── PROJECT_REVIEW.md                 ← static review notes
├── .gitignore                        ← local cruft to ignore
├── config.env                        ← tracked defaults (resources, paths)
├── config.env.local                  ← gitignored private overrides (you create it)
├── compose/
│   └── nextcloud-aio.compose.yaml     ← AIO mastercontainer config
├── cloud-init/
│   ├── build-base.yaml               ← system tools (NO Tailscale)
│   ├── build-latex.yaml              ← +texlive-full + pandoc + pdf tools
│   ├── build-agents.yaml             ← +Claude Code, Codex, Pi (npm)
│   ├── launch-init.yaml.tpl          ← LaTeX & agent VMs: password SSH + dotfiles (no TS)
│   ├── launch-jupyter.yaml.tpl      ← Jupyter container: optional TS + TLJH
│   └── launch-ollama.yaml.tpl       ← Ollama VM: password SSH + Ollama + Docker + OpenWebUI
└── scripts/
    ├── lib.sh                        ← shared helpers (sourced by most scripts)
    ├── build-images.sh               ← builds base/latex/agents images
    ├── validate-cloud-init.sh        ← parses generated cloud-init for all workloads
    ├── new-latex-vm.sh               ← LaTeX workspace + --git + re-entry + auto-exec
    ├── new-agent-vm.sh               ← agent sandbox + --git + re-entry + auto-exec
    ├── new-jupyter-container.sh      ← TLJH system container
    └── new-ollama-vm.sh              ← Ollama + OpenWebUI VM (CPU-first)
```

(No `profiles/` directory anymore — the agent-isolation profile that masked
SSH was removed when workspace VMs moved to host-local SSH.)
