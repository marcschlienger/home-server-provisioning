# Project Review

Review date: 2026-08-27

Scope reviewed:
- `README.md`
- `SETUP.md`
- `config.env`
- `.gitignore`
- `.gitattributes`
- `compose/nextcloud-aio.compose.yaml`
- `cloud-init/*.yaml`
- `cloud-init/*.tpl`
- `scripts/*.sh`
- hidden local files in the project directory

Checks run:
- `shellcheck -x scripts/*.sh` passed.
- The Compose file and documented Incus preseed both passed YAML parsing.
  `docker compose config` was not rerun in the review workspace because the
  Docker CLI was unavailable; the Compose file itself was not changed.
- `bash -n scripts/build-images.sh scripts/lib.sh scripts/new-agent-vm.sh scripts/new-jupyter-container.sh scripts/new-latex-vm.sh scripts/new-ollama-vm.sh scripts/validate-cloud-init.sh` passed.
- `./scripts/validate-cloud-init.sh` passed: 22 passed, 0 failed.
- Documentation links to tracked files resolve.
- Privacy scan found no real hostnames, personal operational usernames,
  domains, IP addresses, repository URLs, or auth keys. The only personal name
  retained is the copyright attribution in `LICENSE`.
- `LICENSE` is present and declares the MIT License.

Live Incus image builds, VM launches, container launches, package installs, and
GPU passthrough were not executed during this static review. The Nextcloud AIO
stack was not started.

## Current Findings

No current documentation or GitHub-readiness issues remain from this static
review. The rebuild path now creates separate LVM filesystems for root and
Incus, relocates daemon-wide image and backup tarballs as well as instance
disks, and documents recovery from a root-backed pool. Instance logs are also
relocated when the installed Incus advertises that capability. Image builds
fail their preflight when the default profile or daemon-wide image store is not
on the configured Incus pool.

## Accepted Tradeoffs

### VM user bootstrap is duplicated in two launch templates

Files:
- `cloud-init/launch-init.yaml.tpl`
- `cloud-init/launch-ollama.yaml.tpl`

The fixed admin user creation, sudo setup, password SSH setup, and optional
dotfiles bootstrap are duplicated between the general VM launch template and the
Ollama launch template. This is intentionally accepted because the templates
diverge after bootstrap and the duplication is small enough to keep explicit.

### VM login is fixed as `admin` / `admin`

This is intentionally accepted because VM SSH is only meant for host-local
access over the private Incus bridge. The host remains the real security
boundary.

### Separate launch scripts stay separate

The LaTeX VM, agent VM, Ollama VM, and Jupyter container have different images,
lifecycle behavior, mounts, and access patterns. Keeping separate scripts is
simpler than hiding those differences behind one generic launcher.

### Incus uses the `dir` storage driver on dedicated ext4

The `dir` driver is less feature-rich and slower for copies and snapshots than
LVM-thin or ZFS. It is retained because it matches the ext4-based host, is easy
to inspect and recover, and the dedicated `incus-lv` still provides the
important capacity boundary from root. Daemon-wide images, backups, and logs
are redirected to custom volumes on the same pool when supported by the
installed Incus version; image and backup relocation are required.

## Residual Verification Limits

This review validates shell syntax, ShellCheck, YAML parsing, template
rendering, placeholder replacement, and documentation consistency. It does not
prove that:
- A fresh `incus admin init --preseed` completes on the target host without an
  existing Incus configuration.
- Incus can launch the configured images/containers on the target host.
- External installer scripts are reachable during first boot.
- TLJH, Ollama, Docker, and OpenWebUI complete successfully on live instances.
- Host-local SSH works with the target host firewall/network setup.
- Jupyter joins the tailnet successfully with a real `JUPYTER_TS_AUTHKEY`.
- GPU passthrough works on the target hardware.
