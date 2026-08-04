# Project Review

Review date: 2026-08-04

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
- `docker compose -f compose/nextcloud-aio.compose.yaml config` passed.
- `bash -n scripts/build-images.sh scripts/lib.sh scripts/new-agent-vm.sh scripts/new-jupyter-container.sh scripts/new-latex-vm.sh scripts/new-ollama-vm.sh scripts/validate-cloud-init.sh` passed.
- `./scripts/validate-cloud-init.sh` passed: 22 passed, 0 failed.
- GitHub readiness scan passed: local `.DS_Store` and generated Gemini note were removed, and no real secret patterns were found.
- `LICENSE` is present and declares the MIT License.

Live Incus image builds, VM launches, container launches, package installs, and
GPU passthrough were not executed during this static review. The Nextcloud AIO
Compose file was rendered with `docker compose config`, but the stack was not
started.

## Current Findings

No current bugs or GitHub-readiness issues remain from this static review.

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

## Residual Verification Limits

This review validates shell syntax, ShellCheck, YAML parsing, template
rendering, placeholder replacement, and documentation consistency. It does not
prove that:
- Incus can launch the configured images/containers on the target host.
- External installer scripts are reachable during first boot.
- TLJH, Ollama, Docker, and OpenWebUI complete successfully on live instances.
- Host-local SSH works with the target host firewall/network setup.
- Jupyter joins the tailnet successfully with a real `JUPYTER_TS_AUTHKEY`.
- GPU passthrough works on the target hardware.
