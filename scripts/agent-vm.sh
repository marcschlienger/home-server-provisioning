#!/usr/bin/env bash
# =============================================================================
# agent-vm.sh — create or re-enter a PERSISTENT agent VM
# (Claude Code / Codex / Pi).
#
# Usage:
#   ./agent-vm.sh <task-name> [--git <repo-name-or-path>]
#
# Options:
#   --git <name|path>   On FIRST run, bind-mount a host directory at
#                       /home/admin/project inside the VM. Bare names resolve
#                       under GIT_REPOS_ROOT; absolute host paths are used as-is.
#                       On re-entry, must match the mount fixed at creation.
#                       To mount a different repo, `incus delete` first.
#
# Behaviour:
#   - First run: creates the VM, mounts the project, waits for cloud-init,
#     drops you into a shell.
#   - Re-entry: re-enters the SAME VM with all state intact.
#       * stopped VM  -> started, then attached
#       * running VM  -> attached (new shell alongside any existing session)
#
# Stop the VM with: incus stop  agent-<task>   (preserves state)
# Destroy with:     incus delete agent-<task>  (truly done)
#
# Access: `incus exec` from the host, OR `ssh admin@<vm-local-ip>`
# (incusbr0 is host-private — not on the LAN or internet).
# No Tailscale is installed on agent VMs.
#
# Isolation note: the VM gets a local login password for inbound host->VM SSH,
# but no private keys — so the agent still can't SSH OUT to your other machines.
# The agent sees only the bind-mounted project dir, and the VM is not on any
# tailnet. That's the isolation; inbound host SSH does not weaken it.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config "$ROOT_DIR/config.env"

TASK=""
GIT_ARG=""

die()   { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,25p' "$0"; }

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --git) require_value --git "${2:-}" || exit 2
           GIT_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *)  [[ -n "$TASK" ]] \
          && { echo "ERROR: unexpected extra argument '$1' (TASK is '$TASK')." >&2; exit 2; }
        TASK="$1"; shift ;;
  esac
done

[[ -n "$TASK" ]] || { usage >&2; exit 2; }
NAME="agent-${TASK}"
# Validate the FINAL name (after the prefix) so we don't silently exceed
# the 63-char DNS-safe limit.
validate_name "$NAME" "vm name (agent-<task>)"

command -v incus >/dev/null 2>&1 || die "incus CLI not found."

# Resolve this before the re-entry branch so an existing VM cannot silently
# ignore a missing or different --git path.
HOST_PROJECT=""
if [[ -n "$GIT_ARG" ]]; then
  HOST_PROJECT=$(resolve_git_path "$GIT_ARG" "$GIT_REPOS_ROOT")
fi

# ── Re-entry: if VM exists, start if needed then exec into it ─────────────────
if incus info "$NAME" &>/dev/null && [[ -n "$HOST_PROJECT" ]]; then
  verify_project_mount "$NAME" "$HOST_PROJECT"
fi
if reenter_if_exists "$NAME"; then
  : # reenter_if_exists exec's into the VM — we don't reach here
fi

# ── First-run path ────────────────────────────────────────────────────────────
EFFECTIVE_DOTFILES_REPO=$(effective_dotfiles_repo "$DOTFILES_REPO")
[[ -n "$EFFECTIVE_DOTFILES_REPO" ]] \
  || die "Set DOTFILES_REPO in config.env.local before launching agent VMs."
validate_simple_string "$EFFECTIVE_DOTFILES_REPO" "DOTFILES_REPO"
validate_simple_string "$DOTFILES_INSTALL_CMD" "DOTFILES_INSTALL_CMD"
validate_dotfiles_repo "$EFFECTIVE_DOTFILES_REPO" "DOTFILES_REPO"

incus image info "$AGENTS_IMAGE" >/dev/null 2>&1 \
  || die "$AGENTS_IMAGE not found. Run: ./scripts/build-images.sh --only agents"

[[ -z "$HOST_PROJECT" ]] || warn_if_bind_mount_owner_mismatch "$HOST_PROJECT"

# ── Build launch-init user-data ───────────────────────────────────────────────
USER_DATA=$(render_template_checked "$ROOT_DIR/cloud-init/launch-init.yaml.tpl" \
  DOTFILES_REPO="$EFFECTIVE_DOTFILES_REPO" \
  INSTALL_CMD="$DOTFILES_INSTALL_CMD")

echo "==> Creating persistent agent VM: $NAME"
incus init "$AGENTS_IMAGE" "$NAME" \
  --vm \
  --storage "$INCUS_STORAGE_POOL" \
  --config "limits.cpu=${AGENT_VM_CPU}" \
  --config "limits.memory=${AGENT_VM_RAM}" \
  --device "root,size=${AGENT_VM_DISK}" \
  --config "user.user-data=${USER_DATA}"

# Attach the VirtioFS project device while the VM is still stopped. This makes
# the mount part of the machine before cloud-init gets its first chance to run.
if [[ -n "$HOST_PROJECT" ]]; then
  echo "==> Mounting ${HOST_PROJECT} -> /home/admin/project"
  if ! incus config device add "$NAME" project disk \
      source="$HOST_PROJECT" \
      path="/home/admin/project"; then
    echo "==> Removing incomplete VM '$NAME' after device attachment failed." >&2
    incus delete "$NAME" --force >/dev/null 2>&1 || true
    die "Could not attach project directory."
  fi
  echo ""
  echo "Agent's changes land in: ${HOST_PROJECT}"
  echo "Inspect & push from the host:"
  echo "  cd ${HOST_PROJECT} && git status && git diff"
  echo ""
fi

if ! incus start "$NAME"; then
  echo "==> Removing incomplete VM '$NAME' after its first start failed." >&2
  incus delete "$NAME" --force >/dev/null 2>&1 || true
  die "Could not start VM."
fi

echo "Re-enter any time with:  ./scripts/agent-vm.sh $TASK"
echo "Or SSH from the host:    ssh admin@\$(incus list $NAME -c4 --format csv | cut -d' ' -f1)"
echo ""
wait_and_enter "$NAME"
