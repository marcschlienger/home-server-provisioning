# Project Review

Review date: 2026-08-28

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
- `shellcheck -x scripts/*.sh systemd/incus-docker-forward` passed.
- The Compose file and documented Incus preseed both passed YAML parsing.
  `docker compose config` was not rerun in the review workspace because the
  Docker CLI was unavailable; the Compose file itself was not changed.
- `bash -n scripts/*.sh` passed.
- `./scripts/validate-cloud-init.sh` passed: 22 passed, 0 failed.
- Launch-script help paths exit successfully without requiring Incus.
- Static lifecycle assertions confirm `incus init` precedes VirtioFS device
  attachment and `incus start` in both workspace VM scripts.
- Documentation links to tracked files resolve.
- Privacy scan found no real hostnames, personal operational usernames,
  domains, IP addresses, repository URLs, or auth keys. The only personal name
  retained is the copyright attribution in `LICENSE`.
- `LICENSE` is present and declares the MIT License.

Live Incus image builds, VM launches, container launches, package installs, and
GPU passthrough were not executed during this static review. The Nextcloud AIO
stack was not started.

## Current Findings

No further obvious correctness or documentation bugs remain from this static
review. Fixes implemented in this pass:

- Renamed the four `new-*` scripts without the misleading prefix.
- Workspace VMs are initialized stopped, receive their VirtioFS project device,
  and only then start. Failed attachment or first start removes the incomplete
  VM.
- Re-entry validates any repeated `--git` path, handles frozen VMs, waits for
  cloud-init, and reports bootstrap failures instead of silently entering an
  incomplete VM.
- The LaTeX image now derives from the agents image, matching the documented
  availability of Claude Code, Codex, and Pi. Image and first-boot checks fail
  if any advertised agent package or executable is absent. The final LaTeX
  build restores Pi after TeX Live's large package transaction and validates
  the derived artifact again before it can be published.
- Dotfiles URLs that cannot work without guest credentials are rejected before
  launch; first boot fails clearly if cloning or installation does not finish.
- First-boot user migration now remains correct when the pre-attached VirtioFS
  mount has already created `/home/admin`.
- Jupyter and Ollama launchers wait for successful cloud-init. One-shot
  user-data is removed from Incus configuration after successful bootstrap.
- Storage selection is explicit for every launched instance; help exits with
  success; bind-mount ownership warnings inspect the directory rather than the
  unrelated invoking account; download commands now fail on HTTP errors.
- Docker's `FORWARD DROP` policy is handled by a tracked, idempotent systemd
  integration that reinstalls scoped `incusbr0` rules after boot and Docker
  restarts, including IPv6 when Docker exposes an IPv6 user chain.
- Every cloud-init `runcmd` script now enables fail-fast behavior. Download
  pipelines were replaced with checked temporary files so a failed download or
  validation cannot be hidden by the exit status of a later command.

## Accepted Tradeoffs

### VM user bootstrap is duplicated in two launch templates

Files:
- `cloud-init/launch-init.yaml.tpl`
- `cloud-init/launch-ollama.yaml.tpl`

The fixed admin user creation, sudo setup, password SSH setup, and optional
dotfiles bootstrap are duplicated between the general VM launch template and the
Ollama launch template. This is intentionally accepted because the templates
diverge after bootstrap and the duplication is small enough to keep explicit.

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

## Possible Larger Improvements (Not Implemented)

### Replace the fixed VM password

Prefer `incus exec` only, or provision per-host SSH public keys and disable
password authentication. This changes the access and recovery model, so it was
not folded into a lifecycle bug-fix pass.

### Pin and verify external software

Several builds intentionally track moving inputs: the Ubuntu image alias,
Node.js LTS installer, latest `yq`, npm packages, TLJH and Ollama installers,
OpenWebUI `main`, and the Nextcloud AIO `latest` image. Pinning versions and
checksums would improve reproducibility and supply-chain control but requires a
deliberate update policy.

### Support private dotfiles securely

The current design supports anonymously readable HTTPS repositories only.
Private repositories need a one-shot credential mechanism that neither embeds a
token in Incus configuration nor leaves a private key in the guest.

### Add live Incus integration tests

A disposable test project could build minimal images and prove device ordering,
cloud-init reruns, UID/GID behavior, failure cleanup, and re-entry against a real
daemon. Static shell/YAML checks cannot prove those runtime properties.

### Define backups for VM-local state

Agent authentication/history and OpenWebUI's Docker volume live outside the
host bind-mounted repositories. If that state matters, it needs an explicit
export or backup policy instead of treating every VM as reconstructible.

## Residual Verification Limits

This review validates shell syntax, ShellCheck, YAML parsing, template
rendering, placeholder replacement, and documentation consistency. It does not
prove that:
- A fresh `incus admin init --preseed` completes on the target host without an
  existing Incus configuration.
- Incus can launch the configured images/containers on the target host.
- External installer scripts are reachable during first boot.
- TLJH, Ollama, Docker, and OpenWebUI complete successfully on live instances.
- The tracked Docker/Incus forwarding unit starts successfully and restores
  live guest internet access on the target host.
- Jupyter joins the tailnet successfully with a real `JUPYTER_TS_AUTHKEY`.
- GPU passthrough works on the target hardware.
