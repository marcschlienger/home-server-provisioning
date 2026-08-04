#!/usr/bin/env bash
# =============================================================================
# new-agent-vm.sh — create or re-enter a PERSISTENT agent VM
# (Claude Code / Codex / Pi).
#
# Usage:
#   ./new-agent-vm.sh <task-name> [--git <repo-name-or-path>]
#
# Options:
#   --git <name|path>   On FIRST run, bind-mount a host directory at
#                       /home/admin/project inside the VM. Bare names resolve
#                       under GIT_REPOS_ROOT; absolute host paths are used as-is.
#                       Ignored on re-entry (mounts are fixed at creation;
#                       to remount a different repo, `incus delete` first).
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
usage() { sed -n '2,25p' "$0"; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --git) require_value --git "${2:-}" || exit 2
           GIT_ARG="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *)  [[ -n "$TASK" ]] \
          && { echo "ERROR: unexpected extra argument '$1' (TASK is '$TASK')." >&2; exit 2; }
        TASK="$1"; shift ;;
  esac
done

[[ -n "$TASK" ]] || usage
NAME="agent-${TASK}"
# Validate the FINAL name (after the prefix) so we don't silently exceed
# the 63-char DNS-safe limit.
validate_name "$NAME" "vm name (agent-<task>)"

command -v incus >/dev/null 2>&1 || die "incus CLI not found."

# ── Re-entry: if VM exists, start if needed then exec into it ─────────────────
if reenter_if_exists "$NAME"; then
  : # reenter_if_exists exec's into the VM — we don't reach here
fi

# ── First-run path ────────────────────────────────────────────────────────────
[[ "$(effective_dotfiles_repo "$DOTFILES_REPO")" != "" ]] \
  || die "Set DOTFILES_REPO in config.env.local before launching agent VMs."
validate_simple_string "$DOTFILES_REPO"      "DOTFILES_REPO"
validate_simple_string "$DOTFILES_INSTALL_CMD" "DOTFILES_INSTALL_CMD"

incus image info "$AGENTS_IMAGE" >/dev/null 2>&1 \
  || die "$AGENTS_IMAGE not found. Run: ./scripts/build-images.sh --only agents"

# ── Resolve git project path ──────────────────────────────────────────────────
HOST_PROJECT=""
if [[ -n "$GIT_ARG" ]]; then
  HOST_PROJECT=$(resolve_git_path "$GIT_ARG" "$GIT_REPOS_ROOT")
  warn_if_uid_mismatch
fi

# ── Build launch-init user-data ───────────────────────────────────────────────
USER_DATA=$(render_template_checked "$ROOT_DIR/cloud-init/launch-init.yaml.tpl" \
  DOTFILES_REPO="$DOTFILES_REPO" \
  INSTALL_CMD="$DOTFILES_INSTALL_CMD")

echo "==> Creating persistent agent VM: $NAME"
incus launch "$AGENTS_IMAGE" "$NAME" \
  --vm \
  --config "limits.cpu=${AGENT_VM_CPU}" \
  --config "limits.memory=${AGENT_VM_RAM}" \
  --device "root,size=${AGENT_VM_DISK}" \
  --config "user.user-data=${USER_DATA}"

# Bind-mount the project directory if provided
if [[ -n "$HOST_PROJECT" ]]; then
  echo "==> Mounting ${HOST_PROJECT} -> /home/admin/project"
  incus config device add "$NAME" project disk \
    source="$HOST_PROJECT" \
    path="/home/admin/project"
  echo ""
  echo "Agent's changes land in: ${HOST_PROJECT}"
  echo "Inspect & push from the host:"
  echo "  cd ${HOST_PROJECT} && git status && git diff"
  echo ""
fi

echo "Re-enter any time with:  ./scripts/new-agent-vm.sh $TASK"
echo "Or SSH from the host:    ssh admin@\$(incus list $NAME -c4 --format csv | cut -d' ' -f1)"
echo ""
wait_and_enter "$NAME"
