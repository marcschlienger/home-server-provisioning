#!/usr/bin/env bash
# =============================================================================
# new-jupyter-container.sh — launch an Incus SYSTEM CONTAINER running TLJH
# (The Littlest JupyterHub).
#
# Usage:
#   ./new-jupyter-container.sh <admin-username> [container-name]
#
# Arguments:
#   admin-username   first JupyterHub admin user. You set the password on
#                    first login via the web UI.
#   container-name   optional, default 'jupyter'. DNS-safe.
#
# Why a system container (not a VM)? TLJH is a single-tenant Python install
# that doesn't need VM-level isolation. Containers boot in seconds.
#
# After launch, access JupyterHub at:
#   - Locally:  http://<container-ip>/
#   - Tailnet:  http://<container-name>/  (if JUPYTER_TS_AUTHKEY was set)
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config "$ROOT_DIR/config.env"

die()   { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,22p' "$0"; exit 1; }

# Catch typos like  `./new-jupyter-container.sh adminuser jupyter extra`
(( $# >= 1 && $# <= 2 )) \
  || die "Expected 1 or 2 arguments (admin-username [container-name]); got $#."

ADMIN_USER="${1:-}"
NAME="${2:-jupyter}"

[[ -n "$ADMIN_USER" ]] || usage
validate_name "$NAME" "container-name"
# admin username must be a valid Linux username
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] \
  || die "Admin username '$ADMIN_USER' is not a valid Linux username."
validate_tailscale_authkey "${JUPYTER_TS_AUTHKEY:-}" "JUPYTER_TS_AUTHKEY"

# ── Validation ────────────────────────────────────────────────────────────────
command -v incus >/dev/null 2>&1 || die "incus CLI not found."
! incus info "$NAME" &>/dev/null \
  || die "Instance '$NAME' already exists. Delete: incus delete $NAME"

# ── Build launch-init user-data from the Jupyter template ─────────────────────
USER_DATA=$(render_template_checked "$ROOT_DIR/cloud-init/launch-jupyter.yaml.tpl" \
  TS_AUTHKEY="${JUPYTER_TS_AUTHKEY:-}" \
  TS_HOSTNAME="$NAME" \
  ADMIN_USER="$ADMIN_USER")

echo "==> Launching Jupyter system container: $NAME (admin user: $ADMIN_USER)"
incus launch "$UBUNTU_REMOTE" "$NAME" \
  --config "limits.cpu=${JUPYTER_CT_CPU}" \
  --config "limits.memory=${JUPYTER_CT_RAM}" \
  --device "root,size=${JUPYTER_CT_DISK}" \
  --config "user.user-data=${USER_DATA}"

echo ""
echo "Container '$NAME' is starting. TLJH bootstrap takes ~10 min."
echo ""
echo "Watch progress:"
echo "  incus exec $NAME -- tail -f /var/log/cloud-init-output.log"
echo ""
if [[ -n "${JUPYTER_TS_AUTHKEY:-}" ]]; then
  echo "When ready, visit from a Tailscale-connected device:"
  echo "  http://$NAME/"
  echo ""
  echo "Local Incus fallback:"
  echo "  incus list $NAME"
  echo "  http://<container-ip>/"
else
  echo "When ready, get the container IP:"
  echo "  incus list $NAME"
  echo ""
  echo "Then visit:"
  echo "  http://<container-ip>/"
fi
echo ""
echo "Log in as '$ADMIN_USER'"
echo "(set the password on first login)."
