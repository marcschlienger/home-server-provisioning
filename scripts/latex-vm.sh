#!/usr/bin/env bash
# =============================================================================
# latex-vm.sh — create or re-enter a persistent LaTeX workspace VM.
#
# Usage:
#   ./latex-vm.sh [vm-name] [--git <repo-name-or-path>]
#
# Options:
#   --git <name|path>   On FIRST run, bind-mount a host directory at
#                       /home/admin/project inside the VM. Bare names resolve
#                       under GIT_REPOS_ROOT (e.g. 'teaching' -> $GIT_REPOS_ROOT/teaching);
#                       absolute host paths are used as-is. On re-entry, the
#                       requested path must match the mount fixed at creation.
#
# Behaviour:
#   - First run: creates the VM, mounts the project, waits for cloud-init,
#     drops you into a shell.
#   - Re-entry: re-enters the same VM (start if stopped, exec if running).
#
# Examples:
#   ./latex-vm.sh                                # default 'latex-ws'
#   ./latex-vm.sh latex-ws --git teaching        # mount $GIT_REPOS_ROOT/teaching
#   ./latex-vm.sh paper --git /mnt/ssd/draft     # absolute host path
#   ./latex-vm.sh latex-ws                       # re-enter later
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config "$ROOT_DIR/config.env"

NAME=""
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
    *)  [[ -n "$NAME" ]] \
          && { echo "ERROR: unexpected extra argument '$1' (vm-name is '$NAME')." >&2; exit 2; }
        NAME="$1"; shift ;;
  esac
done

NAME="${NAME:-latex-ws}"
validate_name "$NAME" "vm-name"

command -v incus >/dev/null 2>&1 || die "incus CLI not found."

HOST_PROJECT=""
if [[ -n "$GIT_ARG" ]]; then
  HOST_PROJECT=$(resolve_git_path "$GIT_ARG" "$GIT_REPOS_ROOT")
fi

# ── Re-entry: if VM exists, start if needed then exec into it ─────────────────
if incus info "$NAME" &>/dev/null && [[ -n "$HOST_PROJECT" ]]; then
  verify_project_mount "$NAME" "$HOST_PROJECT"
fi
if reenter_if_exists "$NAME"; then
  : # process replaced by exec; we don't reach here
fi

# ── First-run path ────────────────────────────────────────────────────────────
EFFECTIVE_DOTFILES_REPO=$(effective_dotfiles_repo "$DOTFILES_REPO")
[[ -n "$EFFECTIVE_DOTFILES_REPO" ]] \
  || die "Set DOTFILES_REPO in config.env.local before launching the LaTeX VM."
validate_simple_string "$EFFECTIVE_DOTFILES_REPO" "DOTFILES_REPO"
validate_simple_string "$DOTFILES_INSTALL_CMD" "DOTFILES_INSTALL_CMD"
validate_dotfiles_repo "$EFFECTIVE_DOTFILES_REPO" "DOTFILES_REPO"

incus image info "$LATEX_IMAGE" >/dev/null 2>&1 \
  || die "$LATEX_IMAGE not found. Run: ./scripts/build-images.sh --only latex"

[[ -z "$HOST_PROJECT" ]] || warn_if_bind_mount_owner_mismatch "$HOST_PROJECT"

USER_DATA=$(render_template_checked "$ROOT_DIR/cloud-init/launch-init.yaml.tpl" \
  DOTFILES_REPO="$EFFECTIVE_DOTFILES_REPO" \
  INSTALL_CMD="$DOTFILES_INSTALL_CMD")

echo "==> Launching LaTeX VM: $NAME"
incus init "$LATEX_IMAGE" "$NAME" \
  --vm \
  --storage "$INCUS_STORAGE_POOL" \
  --config "limits.cpu=${LATEX_VM_CPU}" \
  --config "limits.memory=${LATEX_VM_RAM}" \
  --device "root,size=${LATEX_VM_DISK}" \
  --config "user.user-data=${USER_DATA}"

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
  echo "Project '${HOST_PROJECT}' is at /home/admin/project inside the VM."
  echo "Push from the host with your own credentials:"
  echo "  cd ${HOST_PROJECT} && git push"
  echo ""
fi

if ! incus start "$NAME"; then
  echo "==> Removing incomplete VM '$NAME' after its first start failed." >&2
  incus delete "$NAME" --force >/dev/null 2>&1 || true
  die "Could not start VM."
fi

echo "Re-enter any time with:  ./scripts/latex-vm.sh $NAME"
echo "Or SSH from the host:    ssh admin@\$(incus list $NAME -c4 --format csv | cut -d' ' -f1)"
echo ""
wait_and_enter "$NAME"
