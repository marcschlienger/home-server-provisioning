#!/usr/bin/env bash
# =============================================================================
# ollama-vm.sh — launch an Ubuntu VM with Ollama + OpenWebUI.
#
# Usage:
#   ./ollama-vm.sh [vm-name]
#
# Default name: 'ollama'. Must be DNS-safe.
#
# Runs CPU-only by default. GPU passthrough (AMD RX 580 Vulkan +
# vendor-reset) is a separate Phase 1.5 step — see SETUP.md §5.
#
# After launch:
#   - Ollama API:  http://<vm-ip>:11434
#   - OpenWebUI:   http://<vm-ip>:3000
#   - SSH from host: ssh admin@<vm-ip>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config "$ROOT_DIR/config.env"

die() { echo "ERROR: $*" >&2; exit 1; }

if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  sed -n '2,17p' "$0"
  exit 0
fi

(( $# <= 1 )) \
  || die "Expected at most 1 argument (vm-name); got $#."

NAME="${1:-ollama}"
validate_name "$NAME" "vm-name"

# ── Validation ────────────────────────────────────────────────────────────────
command -v incus >/dev/null 2>&1 || die "incus CLI not found."
incus image info "$BASE_IMAGE" >/dev/null 2>&1 \
  || die "$BASE_IMAGE not found. Run: ./scripts/build-images.sh --only base"
! incus info "$NAME" &>/dev/null \
  || die "Instance '$NAME' already exists. Delete: incus delete $NAME"

# Dotfiles are OPTIONAL for Ollama. Normalize the unedited placeholder URL
# to empty so first boot doesn't try to clone https://github.com/YOUR_USERNAME/dotfiles.
EFFECTIVE_DOTFILES_REPO=$(effective_dotfiles_repo "${DOTFILES_REPO:-}")
validate_simple_string "$EFFECTIVE_DOTFILES_REPO" "DOTFILES_REPO"
validate_simple_string "${DOTFILES_INSTALL_CMD:-stow .}" "DOTFILES_INSTALL_CMD"
validate_dotfiles_repo "$EFFECTIVE_DOTFILES_REPO" "DOTFILES_REPO"

# ── Build launch-init user-data ───────────────────────────────────────────────
USER_DATA=$(render_template_checked "$ROOT_DIR/cloud-init/launch-ollama.yaml.tpl" \
  DOTFILES_REPO="$EFFECTIVE_DOTFILES_REPO" \
  INSTALL_CMD="${DOTFILES_INSTALL_CMD:-stow .}")

echo "==> Launching Ollama VM: $NAME"
incus launch "$BASE_IMAGE" "$NAME" \
  --vm \
  --storage "$INCUS_STORAGE_POOL" \
  --config "limits.cpu=${OLLAMA_VM_CPU}" \
  --config "limits.memory=${OLLAMA_VM_RAM}" \
  --device "root,size=${OLLAMA_VM_DISK}" \
  --config "user.user-data=${USER_DATA}"

echo ""
echo "VM '$NAME' is starting. Waiting for Ollama + Docker (~5-10 min)..."
wait_for_instance "$NAME" 600 \
  || die "VM did not become reachable."
wait_for_cloud_init "$NAME" \
  || die "Ollama cloud-init failed; see the log above."
clear_instance_user_data "$NAME"
echo "VM '$NAME' is ready."
echo ""
echo "Pull a model:"
echo "  incus exec $NAME -- ollama pull llama3.1:8b"
echo "  incus exec $NAME -- ollama run llama3.1:8b 'hello'"
echo ""
echo "Access OpenWebUI:"
echo "  http://\$(incus list $NAME -c 4 -f csv | cut -d' ' -f1):3000"
echo "SSH from the host:"
echo "  ssh admin@\$(incus list $NAME -c 4 -f csv | cut -d' ' -f1)"
echo ""
echo "GPU passthrough is documented in SETUP.md §5 (Phase 1.5)."
