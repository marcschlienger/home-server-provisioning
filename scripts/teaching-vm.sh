#!/usr/bin/env bash
# =============================================================================
# teaching-vm.sh — create or re-enter the persistent teaching workspace.
#
# The workspace deliberately exposes three independent host trees:
#   /home/admin/project                  teaching-src (primary workspace)
#   /home/admin/repos/teaching-private  teaching-private (separate repository)
#   /home/admin/texmf                    personal TEXMF tree
#
# Bare source names are configured in config.env and resolve below
# GIT_REPOS_ROOT. Override them with absolute paths in config.env.local when
# the host stores one of the trees elsewhere.
#
# Usage: ./teaching-vm.sh [vm-name]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config "$ROOT_DIR/config.env"

NAME="${1:-teaching-ws}"
if [[ "$NAME" == -h || "$NAME" == --help ]]; then
  sed -n '2,15p' "$0"
  exit 0
fi
[[ $# -le 1 ]] || { echo "Usage: $0 [vm-name]" >&2; exit 2; }
validate_name "$NAME" "vm-name"

for variable_name in \
    TEACHING_SRC_REPO \
    TEACHING_PRIVATE_REPO \
    TEACHING_TEXMF_ROOT \
    TEACHING_TEXMF_VERIFY_FILE; do
  [[ -n "${!variable_name:-}" ]] \
    || { echo "ERROR: $variable_name is not set." >&2; exit 2; }
done

exec "$SCRIPT_DIR/latex-vm.sh" "$NAME" \
  --git "$TEACHING_SRC_REPO" \
  --mount "$TEACHING_PRIVATE_REPO=/home/admin/repos/teaching-private" \
  --mount "$TEACHING_TEXMF_ROOT=/home/admin/texmf" \
  --verify-tex "$TEACHING_TEXMF_VERIFY_FILE"
