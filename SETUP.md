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
| Storage | NVMe with LVM (`/` + isolated Incus LV); separate ext4 data SSD at `/data` |
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
| **Backups** | Existing off-host backup system | Sync + local incremental + encrypted off-site copies |

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
│   / (host LV) ─────────── Ubuntu + Caddy + Docker          │               │
│   /srv/incus (Incus LV) ─ VM/container storage ───────────┤               │
│   /data/ncdata ────────── Nextcloud AIO data              │               │
│   GIT_REPOS_ROOT ──────── bind-mounted via Incus ─────────┤               │
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
                │  Backup host / off-site      │
                │  storage                     │
                │  → application-level sync    │
                │  → local incremental copies  │
                │  → encrypted off-site copies │
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

### 2.2 Configure the NVMe LVM layout

Ubuntu's guided LVM install can place the full NVMe into a volume group while
creating only a roughly 100 GiB root logical volume. That is easy to miss:
`df` shows the small filesystem, while `vgs` shows the unallocated capacity.
Do not initialize Incus on that small root filesystem. A VM image rebuild can
temporarily require both the old and new images and fill `/`, which also stops
Caddy and Docker from writing. Ubuntu's
[LVM overview](https://documentation.ubuntu.com/server/explanation/storage/about-lvm/)
explains the physical-volume, volume-group, and logical-volume layers used
below.

The current target layout is:

| Allocation | Size | Purpose |
|---|---:|---|
| `ubuntu-vg/ubuntu-lv` mounted at `/` | 250 GiB | Ubuntu, Caddy, Docker, logs, host tools |
| `ubuntu-vg/incus-lv` mounted at `/srv/incus` | 1,200 GiB | Incus instances, build VMs, and image caches |
| Free extents in `ubuntu-vg` | remainder | Online expansion of either LV later |
| Data SSD mounted at `/data` | full device | Nextcloud data and host Git repositories |

Sizes are targets for this hardware, not universal requirements. On different
hardware, keep the same separation and leave some volume-group space free.

Inspect the actual device and LVM names before changing anything:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
sudo pvs
sudo vgs
sudo lvs -o lv_name,vg_name,lv_size
```

On the documented layout, grow the installer-created 100 GiB root LV to
250 GiB. `--resizefs` grows ext4 at the same time and does not require a reboot:

```bash
sudo lvextend --resizefs --size 250G /dev/ubuntu-vg/ubuntu-lv
df -hT /
```

Create the dedicated Incus LV and filesystem. **Run `mkfs.ext4` only on the
newly created `incus-lv`; formatting an existing LV destroys its contents.**

```bash
sudo lvcreate --size 1200G --name incus-lv ubuntu-vg
sudo mkfs.ext4 -L incus /dev/ubuntu-vg/incus-lv
sudo mkdir -p /srv/incus
sudo blkid /dev/ubuntu-vg/incus-lv
```

Add one entry to `/etc/fstab`, using the UUID printed by `blkid`. Either UUID
form is valid; this runbook follows Ubuntu's `/dev/disk/by-uuid/` style:

```fstab
/dev/disk/by-uuid/<INCUS_FILESYSTEM_UUID> /srv/incus ext4 defaults,noatime 0 2
```

Do not paste the complete human-readable `blkid` output into `fstab`; reduce it
to the single entry above. Validate and mount without rebooting:

```bash
sudo findmnt --verify --verbose
sudo systemctl daemon-reload
sudo mount /srv/incus
findmnt /srv/incus
df -h / /srv/incus
sudo vgs
```

`findmnt` must show `/srv/incus` backed by `incus-lv` before Incus storage is
created. A later reboot will mount it automatically.

Mount the separate data SSD at `/data` by UUID as well. If the device already
contains data, **do not format or repartition it**. Identify the correct ext4
partition from `lsblk -f` and `blkid`, create the mount point, and add a second
`fstab` entry:

```bash
sudo mkdir -p /data
sudo blkid /dev/sda1
```

```fstab
/dev/disk/by-uuid/<DATA_FILESYSTEM_UUID> /data ext4 defaults,noatime 0 2
```

Then validate and mount it:

```bash
sudo findmnt --verify --verbose
sudo systemctl daemon-reload
sudo mount /data
findmnt /data
df -h /data
```

On replacement hardware with a blank data SSD, partition and format the new
device only after identifying it unambiguously, then restore the data from
backup. Never copy a device name such as `/dev/sda` from this runbook without
checking the target host; enumeration can change between boots and machines.

Both LVs can be expanded online later. Check `vgs` first, then add only the
required amount, for example:

```bash
sudo vgs
sudo lvextend --resizefs --size +100G /dev/ubuntu-vg/incus-lv
```

### 2.3 Install Tailscale (on the host)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh        # --ssh enables Tailscale SSH for this host
```

Sign in via the URL it prints. From now on you can SSH to this host over
Tailscale by hostname.

### 2.4 Install and initialize Incus

Ubuntu 26.04 ships Incus in the main repos:

```bash
sudo apt install -y incus incus-extra
# incus-extra brings incus-benchmark, incus-migrate, lxd-to-incus, etc.
sudo adduser $USER incus-admin
# Log out and back in (or `newgrp incus-admin`) for group to take effect
```

After logging out and back in, create the pool on the mounted Incus filesystem
and initialize the bridge and default profile. The explicit preseed prevents an
accidental root-backed pool under `/var/lib/incus`. See the official
[`incus admin init` preseed reference](https://linuxcontainers.org/incus/docs/main/reference/manpages/incus/admin/init/)
and [profile documentation](https://linuxcontainers.org/incus/docs/main/profiles/)
for the schema and device inheritance model:

```bash
sudo mkdir -p /srv/incus/pool
incus admin init --preseed <<'EOF'
config: {}
networks:
- name: incusbr0
  type: bridge
  config:
    ipv4.address: auto
    ipv4.nat: "true"
    ipv6.address: auto
    ipv6.nat: "true"
storage_pools:
- name: vms
  driver: dir
  description: Dedicated Incus storage
  config:
    source: /srv/incus/pool
profiles:
- name: default
  description: Default Incus profile
  config: {}
  devices:
    eth0:
      name: eth0
      network: incusbr0
      type: nic
    root:
      path: /
      pool: vms
      type: disk
EOF
```

This uses Incus's `dir` storage driver on the dedicated ext4 filesystem. The
[storage overview](https://linuxcontainers.org/incus/docs/main/explanation/storage/)
describes pools and volumes; the
[`dir` driver reference](https://linuxcontainers.org/incus/docs/main/reference/storage_dir/)
documents its behavior and tradeoffs.

The profile places instance root disks on `vms`, but Incus also has
daemon-wide image and backup tarballs. Put those on the dedicated filesystem
as custom volumes as well. Incus documents this arrangement under
[custom storage volumes](https://linuxcontainers.org/incus/docs/main/howto/storage_volumes/),
while the exact daemon keys and required API extensions are listed in the
[server configuration reference](https://linuxcontainers.org/incus/docs/main/server_config/):

```bash
incus storage volume create vms daemon-images
incus storage volume create vms daemon-backups
incus config set storage.images_volume=vms/daemon-images
incus config set storage.backups_volume=vms/daemon-backups
```

Newer Incus versions can also relocate instance logs. Configure that optional
volume only if the server advertises the `daemon_storage_logs` API extension:

```bash
if incus info | grep -q 'daemon_storage_logs'; then
  incus storage volume create vms daemon-logs
  incus config set storage.logs_volume=vms/daemon-logs
fi
```

Verify the failure boundary before building images:

```bash
incus storage list
incus storage volume list vms
incus storage show vms
incus profile show default
incus config show
findmnt /srv/incus
```

There should be one pool named `vms`, its source should be
`/srv/incus/pool`, and the default profile's root device should say
`pool: vms`. The image and backup server settings must point to their custom
volumes on `vms`; the log setting is optional and version-dependent. Only the
small Incus database, daemon state, and—on older versions—instance logs remain
below `/var/lib/incus` on root.

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

### 2.5 Install Docker (for Nextcloud AIO)

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

Docker sets the host's forwarding policy to `DROP`. Without an explicit
exception, Incus guests can receive DHCP leases and resolve DNS through
`incusbr0` but their forwarded HTTPS connections time out. Install the tracked
systemd integration after both Docker and Incus are present:

```bash
sudo ./scripts/install-incus-docker-forwarding.sh
```

The service keeps the following scoped policy at the head of `DOCKER-USER`:

- traffic originating on `incusbr0` may be forwarded;
- only established or related forwarded traffic may return to `incusbr0`.

It applies the same policy to IPv6 when Docker creates an IPv6 `DOCKER-USER`
chain. The unit is tied to `docker.service`, so the idempotent helper runs after
boot and after Docker restarts. Re-run the installer after pulling a changed
unit or helper from this repository.

Verify forwarding before building images:

```bash
sudo systemctl status incus-docker-forward.service
sudo iptables -S DOCKER-USER
incus exec <existing-instance> -- curl -4 -I --connect-timeout 10 https://github.com
```

### 2.6 Install Caddy (reverse proxy)

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

### 2.7 Configure the host git workspace directory

`GIT_REPOS_ROOT` is the host-side parent directory for repos when you pass a
bare name to `--git`. Set it in `config.env` to wherever your SSD storage is
mounted. The default matches the recommended `/data` mount:

```bash
GIT_REPOS_ROOT="/data/git"
sudo mkdir -p "$GIT_REPOS_ROOT"
sudo chown $USER:$USER "$GIT_REPOS_ROOT"
```

Change this path if you mount repository storage somewhere else. This is where
you clone repos from GitHub / GitLab / Codeberg using your own SSH credentials.
They get bind-mounted into VMs read-write.

You can also bypass `GIT_REPOS_ROOT` for a single VM by passing an absolute
host path:

```bash
./scripts/agent-vm.sh refactor-foo --git /mnt/other-ssd/repos/project-foo
```

### 2.8 Bring up Nextcloud AIO

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

### 2.9 Get this repository onto the server

This repository (`cloud-init/`, `compose/`, `scripts/`, `config.env`,
`SETUP.md`) is the source of truth for everything below. Put it on the
freshly-installed server by whichever path you prefer:

```bash
# Option A — clone from your git server (Codeberg / GitHub / GitLab / private):
cd ~/
git clone <your-URL-for-this-repo> home-server-provisioning
cd home-server-provisioning

# Option B — rsync from your workstation if you keep it locally:
rsync -av ~/path/to/home-server-provisioning/ user@server:~/home-server-provisioning/
```

The point is just "make these files available on the server." Git is the
clean path; rsync works fine if you don't want to publish this anywhere.

### 2.10 Configure `config.env` and `config.env.local`

There are **two** config files; launch and build scripts source both (`.local`
second, so it overrides). The validator deliberately reads tracked defaults
only. The split keeps private local values out of Git.

**`config.env`** — committed to git. Edit it for shared defaults (resource
sizes, image names, and the GIT_REPOS_ROOT path).

**`config.env.local`** — gitignored. This is where private local values go.
Create it on the new host if needed:

```bash
cat > config.env.local <<'EOF'
# An anonymously readable dotfiles repo (overrides the placeholder).
DOTFILES_REPO="https://github.com/YOUR_USER/dotfiles.git"

# Optional: put JupyterHub on your tailnet. Prefer a one-time, pre-authorized
# key and store it only here; leave empty when Jupyter should remain local.
JUPYTER_TS_AUTHKEY=""
EOF
chmod 600 config.env.local
```

Notes:
- `DOTFILES_INSTALL_CMD` default is `stow */` — change in `.local` only if
  your repo uses a different layout. Must be a one-line command without
  single quotes or newlines (the launch scripts reject those).
- The unedited placeholder URL `https://github.com/YOUR_USERNAME/dotfiles`
  is treated as "no dotfiles" by the optional-dotfiles workloads
  (Ollama). LaTeX and agent VMs require a real URL and will refuse to
  launch with the placeholder.
- VMs intentionally receive no SSH key or Git credential. `DOTFILES_REPO` must
  therefore be anonymously readable; private-repository credential injection
  is not implemented. For compatibility, the launchers translate
  `git@github.com:OWNER/REPO` to its anonymous HTTPS form.
- VM SSH uses the fixed local login `admin` / `admin`. This is only for the
  host-private Incus bridge; do not expose VM SSH beyond that.
- The fixed VM SSH password is rendered into Incus cloud-init user-data at
  launch time, so treat this repository as local machine configuration.
- `JUPYTER_TS_AUTHKEY` is only used by the Jupyter container. VMs still do
  not install or use Tailscale. If set, it must start with `tskey-auth-`.
  Prefer a one-time, pre-authorized key; launch-time user-data is removed from
  the Incus instance configuration after cloud-init succeeds.

### 2.11 Build the Incus images

```bash
./scripts/build-images.sh
```

Images build in dependency order: base → agents → LaTeX. The LaTeX image
derives from the agents image so it carries Node.js 22, native Claude, and the
small Codex/Pi installer scripts as well as TeX. Expected timing is base ~10
min, agents ~5 min, and LaTeX ~30-40 min (texlive-full): roughly 50 min total
for the first run.

Claude Code is installed as a native system package from Anthropic's signed
stable APT channel. Codex uses its official standalone installer, avoiding
npm's platform-specific package failure mode. Pi uses its official installer;
that installer is still npm-backed and therefore keeps Ubuntu's Node.js 22 and
npm packages as Pi dependencies. Codex and Pi are deliberately not baked into
published images. Each workspace installs them once during first boot, directly
into its writable filesystem; Pi's npm prefix is fixed at `/usr/local`.
Image builds validate Node and Claude, while first boot and every re-entry
validate the complete Node, Claude, Codex, and Pi stack. New workspace creation
therefore takes a little longer and requires internet access, which is already
required for UV and dotfiles.
Package-manager Claude installations do not self-update; a later image rebuild
picks up the then-current stable package.

Existing VMs are independent of later image rebuilds:

- Keep a VM if `cloud-init status --long` reports `done` and
  `/usr/local/sbin/verify-agent-clis` succeeds. It needs no migration.
- A VM whose first boot ended with `status: error` keeps that failed cloud-init
  state and old user-data. Preserve any VM-local files you need, then delete and
  recreate it; the host-mounted `/home/admin/project` is already outside the VM.
- Rebuilding an image changes only newly created VMs. It never modifies or
  repairs an existing VM.

Subsequent rebuilds of one image only:
```bash
./scripts/build-images.sh --only base
./scripts/build-images.sh --only latex
./scripts/build-images.sh --only agents
```

Monitor both failure domains during a build:

```bash
watch -n 5 'df -h / /srv/incus'
```

The script preserves the previous aliased image until its replacement has been
published successfully. After a successful rebuild, `incus image list` can
therefore contain an older image with a blank alias. Once the replacement is
verified, delete only the identified obsolete fingerprint through Incus:

```bash
incus image list
incus image delete <obsolete-unaliased-fingerprint>
```

Never remove files directly from `/var/lib/incus` or `/srv/incus/pool`.
`build-images.sh` checks that the default profile uses `INCUS_STORAGE_POOL` and
that `storage.images_volume` points to a custom volume on that pool. It aborts
before launching a build if either isolation setting is missing. It also runs
the repository's cloud-init validator before creating any build VM.

### 2.12 VM login

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

### 2.13 Launch the persistent workloads

**LaTeX workspace** (teaching worksheets):
```bash
./scripts/latex-vm.sh latex-ws \
  --git teaching-worksheets \
  --mount latex-styles=/home/admin/texmf/tex/latex/local
# Script waits for cloud-init then drops you into a shell. Re-enter later
# without the flags; every mount remains attached to the VM.
```

**Teaching-agent workspace** (public sources, private assessments, and the two
published TeX repositories kept as separate host directories):

```bash
# Clone these once on the server below GIT_REPOS_ROOT (alongside the two
# teaching repositories):
source ./config.env
[[ ! -f ./config.env.local ]] || source ./config.env.local
cd "$GIT_REPOS_ROOT"
git clone https://github.com/marcschlienger/mtex.git
git clone https://github.com/marcschlienger/mstuff.git

# Then launch from home-server-provisioning. The four default directory names
# are teaching-src, teaching-private, mtex, and mstuff.
cd /path/to/home-server-provisioning
# Override any of these with an absolute path in config.env.local when needed.
./scripts/teaching-vm.sh teaching-ws
```

Inside the VM the paths are stable:

```text
/home/admin/repos/teaching-src      teaching-src
/home/admin/repos/teaching-private  teaching-private
/home/admin/texmf/mtex              mtex
/home/admin/texmf/mstuff            mstuff
```

The launcher sets `TEXMFHOME` to the two complete TDS trees, then verifies the
`msheet`, `mtest`, `mexam`, and `mtalk` classes plus the shared style files with
`kpsewhich` before opening the shell. Change `TEACHING_TEXMF_VERIFY_FILES` in
`config.env.local` to adjust these probes. The repositories remain independent;
Nextcloud is not mounted into the teaching workspace.

The dotfiles repository contains the shared skills as the `teaching-agent`
Stow package. New VMs install it automatically through the default `stow */`.
After updating an existing VM's dotfiles clone, expose the new package once
with `cd ~/.dotfiles && stow -R teaching-agent`.

**JupyterHub** (small group / personal):
```bash
./scripts/jupyter-container.sh adminuser jupyter
# When the script reports ready, visit http://jupyter/ from a Tailscale-connected
# device if JUPYTER_TS_AUTHKEY is set; otherwise use http://<container-ip>/.
```

**Ollama + OpenWebUI**:
```bash
./scripts/ollama-vm.sh ollama
# When the script reports ready, visit http://<vm-ip>:3000
incus exec ollama -- ollama pull llama3.1:8b
```

### 2.14 Verify host and VM connectivity

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

The configured teaching launcher keeps four host repositories independent:

```text
/home/admin/repos/teaching-src      teaching-src
/home/admin/repos/teaching-private  teaching-private
/home/admin/texmf/mtex              mtex
/home/admin/texmf/mstuff            mstuff
```

The tracked defaults are the `TEACHING_*` values in `config.env`. Override
different local repository paths, the explicit `TEXMFHOME`, or the probe list
in `config.env.local`. Both TeX repositories retain their standard TDS layout;
they are not copied or merged into a generated third tree.

```bash
source ./config.env
[[ ! -f ./config.env.local ]] || source ./config.env.local
cd "$GIT_REPOS_ROOT/teaching-src"
git pull

# First launch and every later re-entry use the same command.
./scripts/teaching-vm.sh teaching-ws

# Inside the VM:
#   the shell starts in /home/admin/repos
#   enter teaching-src or teaching-private as needed
#   run claude, codex, or pi
#   build with latexmk -pdf main.tex

# Back on the host, review and push with your own credentials.
cd "$GIT_REPOS_ROOT/teaching-src"
git status
git push
```

The wrapper verifies every configured `.cls` and `.sty` file with `kpsewhich`
before opening a shell. A separate non-interactive check can also compile a
representative document from either source repository:

```bash
./scripts/verify-teaching-vm.sh teaching-ws
./scripts/verify-teaching-vm.sh teaching-ws --tex src:path/to/worksheet.tex
./scripts/verify-teaching-vm.sh teaching-ws --tex private:path/to/solution.tex
```

For other combinations, `--mount` is repeatable. A bare source name resolves
below `GIT_REPOS_ROOT`, just like `--git`; an absolute source path also works.
Extra repositories are deliberately limited to `/home/admin/repos/...` and TeX
inputs to `/home/admin/texmf...`. Every device is attached while the VM is
stopped, before its first boot.

```bash
./scripts/latex-vm.sh paper \
  --git draft \
  --mount references=/home/admin/repos/references \
  --mount latex-styles=/home/admin/texmf/tex/latex/local \
  --verify-tex my-style.sty
```

TeX Live normally searches `/home/admin/texmf` as the `admin` user's private
TeX tree. Choose the mount point to match the style repository's layout:

- If the repository already contains `tex/latex/<package>/*.sty` or `.cls`,
  mount its root at `/home/admin/texmf`.
- If `.sty` and `.cls` files sit directly in the repository root, mount it at
  `/home/admin/texmf/tex/latex/local` as in the example above.
- For multiple complete TDS repositories, mount each below
  `/home/admin/texmf` and pass a brace-delimited list such as
  `--texmf-home '{/home/admin/texmf/mtex,/home/admin/texmf/mstuff}'`.

`--verify-tex` is repeatable. An explicit `--texmf-home` is persisted for POSIX
login shells and zsh in the VM, and is also applied directly during checks.

Inside the VM, confirm that TeX can find a file:

```bash
kpsewhich -var-value=TEXMFHOME
kpsewhich my-style.sty
```

The flags are optional on later re-entry because Incus persists the devices.
Repeating them is useful as a safety check: the launcher verifies every
requested host-to-guest mapping.

An older teaching VM uses the asymmetric `/home/admin/project` layout. Recreate
it to adopt the symmetric repository paths; the host repositories remain
untouched:

```bash
incus delete <old-teaching-vm-name> --force
./scripts/teaching-vm.sh teaching-ws
# Exit the VM shell, then verify all four mounts and the TeX inputs:
./scripts/verify-teaching-vm.sh teaching-ws
```

If only one TeX repository is needed in another workspace, add only that tree.
For a flat style repository, use `path=/home/admin/texmf/tex/latex/local`
instead. Device names must be unique. To replace a mapping, stop the VM, run
`incus config device remove <vm> <device-name>`, and add it again.

### 3.2 Running an agent on a project (persistent VM)

```bash
# Clone the project on the host (only first time):
source ./config.env
[[ ! -f ./config.env.local ]] || source ./config.env.local
cd "$GIT_REPOS_ROOT"
git clone git@github.com:user/project-foo.git

# First run: creates the VM 'agent-refactor-foo' with the project mounted.
./scripts/agent-vm.sh refactor-foo --git project-foo
# (drops you into a shell inside the VM)

# Inside the VM: tmux, agents commit to a branch.
# Agent should commit to e.g. agent/refactor-foo branch — NOT main.

# Exit the shell (Ctrl-D). The VM KEEPS RUNNING in the background;
# partial work, agent auth state, shell history all persist.
# When you want to free the resources between sessions:
#   incus stop agent-refactor-foo

# Re-enter later — same command, no --git needed:
./scripts/agent-vm.sh refactor-foo

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

Use the existing backup system rather than introducing another backup stack.
At minimum, preserve independent local and encrypted off-site copies:

| Tier | What | How |
|---|---|---|
| Application-level sync | Nextcloud data | Existing Nextcloud-compatible sync workflow |
| Local incremental | Snapshot of synced data and host repositories | Existing incremental-copy workflow |
| Off-site copy | Important host data | Encrypted backup to one or more independent providers |

Point the existing backup workflow at the new sources:

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
- OpenWebUI chats live inside a Docker volume in the Ollama VM and are not
  covered by the host bind mounts. The default policy treats them as
  disposable. If chat history matters, add an explicit export or backup from
  inside that VM rather than assuming the host backup can see the volume.

### If you later install ZFS root

Add ZFS snapshots + `syncoid` as a **fast VM-level tier**, layered alongside
the off-host backups rather than replacing them. Install:
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

When you bind-mount a host repo into a VM with `--git` or `--mount`, Incus
presents it to the guest through VirtioFS. The primary `--git` repository is at
`/home/admin/project`; extra paths are explicit. VirtioFS preserves numeric
ownership and permissions. The image's `admin` user is UID/GID 1000:1000, so it
must have access through the directory's owner, group, mode bits, or ACLs.

### The common case (works out of the box)

If you installed Ubuntu Server normally and you are the first/only user, your
host account is UID 1000 and GID 1000 — the same as the VM user.
Files written by the agent inside the VM appear owned by you on the host,
and vice versa. Nothing to configure.

### The edge case (your host UID is not 1000)

If the mounted directory belongs to another UID/GID (multi-user system, shared
repository, or non-standard account setup):

- Files written by the agent appear under a different owner on the host
- You may not be able to read/edit them from the host without `sudo`
- The launch scripts warn when the mount root is not owned by 1000:1000. This
  is a useful signal, not proof of failure: group permissions or ACLs may grant
  correct access, and files deeper in the tree may have different owners.

`raw.idmap` is a container-only option and does not solve this for VMs. Choose
one of these approaches before putting important work in a bind mount:

1. **Preferred for this single-user server:** keep each mounted repository
   owned by UID/GID 1000:1000. This matches the image's `admin` user and
   requires no translation.

2. **For a host account with another UID:** establish a shared numeric group or
   POSIX ACL policy that grants both the host account and VM UID 1000 access to
   the repository. Apply it to a test repository first and verify creation,
   modification, and deletion in both directions. The launch scripts warn about
   the mismatch but deliberately do not rewrite ownership recursively.

3. **For a permanent multi-user design:** make the VM user UID/GID configurable
   in the image templates and rebuild the images. Do not try to repair a
   mismatch by recursively changing the ownership of all `/data` content.

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

### Host root fills during an Incus image build

Typical symptoms are `No space left on device` from the image build followed by
unrelated host services such as Caddy or Docker failing to write. Check bytes,
inodes, the LVM allocation, and the largest root directories:

```bash
df -hT / /srv/incus /data
df -ih / /srv/incus /data
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
sudo pvs
sudo vgs
sudo lvs -o lv_name,vg_name,lv_size
sudo du -xhd1 / 2>/dev/null | sort -h
sudo du -xhd1 /var/lib 2>/dev/null | sort -h
sudo docker system df -v
incus list --all-projects
incus image list
```

With the `dir` driver, `incus storage info` reports usage of the backing
filesystem, not just the bytes owned by Incus. Use `du` on the Incus data path
when distinguishing Incus usage from other consumers of the same filesystem.

Do not run broad Docker volume pruning and do not delete runtime files by hand.
If an Incus build instance is disposable, delete it through Incus:

```bash
incus delete <failed-build-instance> --force
```

Delete obsolete images by alias or fingerprint only after checking
`incus image list`. The Incus
[image-handling documentation](https://linuxcontainers.org/incus/docs/main/image-handling/)
also explains cached remote images and automatic cache expiry:

```bash
incus image delete <obsolete-alias-or-fingerprint>
```

If root has free LVM extents and only needs emergency headroom, extend it
online with `lvextend --resizefs`. Use the allocation in section 2.2 rather
than consuming `100%FREE`, so capacity remains available for the isolated
Incus LV.

### Migrate an existing root-backed Incus pool

Use this procedure when Incus was initialized before `/srv/incus` existed and
its `dir` pool source is below `/var/lib/incus`. First complete the LV,
filesystem, `fstab`, and mount steps in section 2.2. Then create the new pool:

```bash
sudo mkdir -p /srv/incus/pool
incus storage create vms dir source=/srv/incus/pool
incus storage volume create vms daemon-images
incus storage volume create vms daemon-backups
incus config set storage.images_volume=vms/daemon-images
incus config set storage.backups_volume=vms/daemon-backups
if incus info | grep -q 'daemon_storage_logs'; then
  incus storage volume create vms daemon-logs
  incus config set storage.logs_volume=vms/daemon-logs
fi
```

Inspect all projects before deciding whether existing instances are disposable:

```bash
incus list --all-projects
incus image list
incus storage list
```

To retain an instance, stop it and move its root volume through Incus:

```bash
incus stop <instance>
incus move <instance> --storage vms
incus start <instance>
```

This follows Incus's documented
[instance and storage-volume move procedure](https://linuxcontainers.org/incus/docs/main/howto/storage_move_volume/).

When no instances remain on the old pool, point the default profile at `vms`.
If the profile already has a root device, update it:

```bash
incus profile device set default root pool=vms
```

If that command reports `Device doesn't exist`, inspect the profile. Add the
missing root device only when there is no other `type: disk`, `path: /` device:

```bash
incus profile show default
incus profile device add default root disk path=/ pool=vms
```

Verify the profile before removing the old pool:

```bash
incus profile show default
incus storage show vms
incus storage show default
```

The root device must say `pool: vms`. If `incus storage show default` confirms
that nothing uses the old pool, remove it through Incus:

```bash
incus storage delete default
incus storage list
df -h / /srv/incus
```

`Storage pool not found` at the deletion step simply means the old pool was
already removed. The Incus daemon's small database and network state remain in
`/var/lib/incus`; that is expected and should not be deleted.

### Cloud-init failure during image build
```bash
# build-images.sh now dumps the tail of the cloud-init log on failure.
# Manually inspect a build VM if it's still around:
incus exec build-base-<timestamp> -- cat /var/log/cloud-init-output.log
```

### Incus VM has no network
- Check `incus network show incusbr0`
- Verify the persistent Docker/Incus forwarding integration:
  `sudo systemctl status incus-docker-forward.service`
- Inspect the effective rules: `sudo iptables -S DOCKER-USER`
- Reinstall tracked service updates with
  `sudo ./scripts/install-incus-docker-forwarding.sh`
- `incus exec <name> -- ip a`

### Can't SSH into a VM
- Get the VM's host-private IP: `incus list <name> -c4`
- SSH from the HOST (incusbr0 isn't reachable from the LAN):
  `ssh admin@<that-ip>`
- If you need to reset the fixed VM user's password after launch:
  `incus exec <name> -- bash -c 'echo "admin:admin" | chpasswd && printf "PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n" > /etc/ssh/sshd_config.d/99-vm-password.conf && (systemctl reload ssh || systemctl restart ssh)'`

### Dotfiles didn't apply
- Verify `DOTFILES_REPO` is anonymously readable; guest VMs receive no Git
  credential, and embedding a token in cloud-init or a URL would expose it.
- `incus exec <name> -- ls /home/admin/.dotfiles`
- `incus exec <name> -- tail /var/log/cloud-init-output.log`

### LaTeX workspace has no dotfiles or agent CLIs

Existing VMs do not inherit changes from a rebuilt image. Inspect the original
first boot before replacing one:

```bash
incus exec latex-ws -- cloud-init status --long
incus exec latex-ws -- tail -n 100 /var/log/cloud-init-output.log
incus exec latex-ws -- sh -c 'ls -ld /home/admin/.dotfiles; command -v claude codex pi'
```

For a VM whose cloud-init status is `done`, the instance-local agent installers
can be rerun safely and then verified:

```bash
incus exec latex-ws -- /usr/local/sbin/install-codex-cli
incus exec latex-ws -- /usr/local/sbin/install-pi-cli
incus exec latex-ws -- /usr/local/sbin/verify-agent-clis
```

If cloud-init reports `error`, recreate the VM instead. Rebuild the dependency
chain first only when the published images themselves are old:

```bash
./scripts/build-images.sh --only agents
./scripts/build-images.sh --only latex
```

Then recreate the LaTeX VM. Deleting it destroys VM-local history and
credentials, so first preserve anything important outside the VirtioFS-mounted
project. Files under `/home/admin/project` already live on the host.

```bash
incus stop latex-ws
incus delete latex-ws
./scripts/latex-vm.sh latex-ws --git teaching-worksheets
```

### Agent VM has no project files
- Verify the source path exists on host: `ls "$GIT_REPOS_ROOT/<repo>"`, or
  check the absolute path you passed to `--git`
- Verify the device was added: `incus config device show <name>`
- Verify mount inside: `incus exec <name> -- ls /home/admin/project`

---

## 8. References

- [Ubuntu Server](https://ubuntu.com/server)
- [Ubuntu LVM guide](https://documentation.ubuntu.com/server/explanation/storage/about-lvm/)
- [Incus documentation](https://linuxcontainers.org/incus/docs/main/)
- [Incus initialization and preseed reference](https://linuxcontainers.org/incus/docs/main/reference/manpages/incus/admin/init/)
- [Incus profiles](https://linuxcontainers.org/incus/docs/main/profiles/)
- [Incus storage concepts](https://linuxcontainers.org/incus/docs/main/explanation/storage/)
- [Incus storage-pool management](https://linuxcontainers.org/incus/docs/main/howto/storage_pools/)
- [Incus directory storage driver](https://linuxcontainers.org/incus/docs/main/reference/storage_dir/)
- [Incus custom storage volumes](https://linuxcontainers.org/incus/docs/main/howto/storage_volumes/)
- [Incus server configuration keys](https://linuxcontainers.org/incus/docs/main/server_config/)
- [Incus instance and volume migration](https://linuxcontainers.org/incus/docs/main/howto/storage_move_volume/)
- [Incus image handling and cache](https://linuxcontainers.org/incus/docs/main/image-handling/)
- Tailscale: https://tailscale.com/kb/
- Caddy: https://caddyserver.com/docs/
- Nextcloud AIO: https://github.com/nextcloud/all-in-one
- TLJH (JupyterHub): https://tljh.jupyter.org/
- Ollama: https://github.com/ollama/ollama
- OpenWebUI: https://docs.openwebui.com/
- vendor-reset: https://github.com/gnif/vendor-reset
- The backup tools and providers selected for this installation

---

## 9. File Layout Reference

```
home-server-provisioning/
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
│   ├── build-agents.yaml             ← +Node 22, Claude, Codex/Pi installers
│   ├── build-latex.yaml              ← agent prerequisites + TeX/PDF tools
│   ├── launch-init.yaml.tpl          ← VM user, dotfiles, Codex/Pi first boot
│   ├── launch-jupyter.yaml.tpl      ← Jupyter container: optional TS + TLJH
│   └── launch-ollama.yaml.tpl       ← Ollama VM: password SSH + Ollama + Docker + OpenWebUI
└── scripts/
    ├── lib.sh                        ← shared helpers (sourced by most scripts)
    ├── build-images.sh               ← builds base → agents → LaTeX images
    ├── validate-cloud-init.sh        ← parses generated cloud-init for all workloads
    ├── latex-vm.sh                   ← LaTeX workspace + repeatable repo mounts
    ├── teaching-vm.sh                ← configured three-tree teaching workspace
    ├── verify-teaching-vm.sh         ← mounts, TEXMF, optional LaTeX build check
    ├── agent-vm.sh                   ← agent sandbox + repeatable repo mounts
    ├── jupyter-container.sh          ← TLJH system container
    └── ollama-vm.sh                  ← Ollama + OpenWebUI VM (CPU-first)
```

(No `profiles/` directory anymore — the agent-isolation profile that masked
SSH was removed when workspace VMs moved to host-local SSH.)
