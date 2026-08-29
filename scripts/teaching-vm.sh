#!/usr/bin/env bash
# =============================================================================
# teaching-vm.sh — create or re-enter the persistent teaching workspace.
#
# The workspace deliberately exposes four independent host repositories:
#   /home/admin/repos/teaching-src      teaching-src
#   /home/admin/repos/teaching-private  teaching-private (separate repository)
#   /home/admin/texmf/mtex              mtex TDS tree
#   /home/admin/texmf/mstuff            mstuff TDS tree
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
    TEACHING_MTEX_REPO \
    TEACHING_MSTUFF_REPO \
    TEACHING_TEXMF_HOME \
    TEACHING_TEXMF_VERIFY_FILES; do
  [[ -n "${!variable_name:-}" ]] \
    || { echo "ERROR: $variable_name is not set." >&2; exit 2; }
done

read -r -a texmf_verify_files <<< "$TEACHING_TEXMF_VERIFY_FILES"
latex_vm_args=(
  "$NAME"
  --mount "$TEACHING_SRC_REPO=/home/admin/repos/teaching-src"
  --mount "$TEACHING_PRIVATE_REPO=/home/admin/repos/teaching-private"
  --mount "$TEACHING_MTEX_REPO=/home/admin/texmf/mtex"
  --mount "$TEACHING_MSTUFF_REPO=/home/admin/texmf/mstuff"
  --workdir /home/admin/repos
  --texmf-home "$TEACHING_TEXMF_HOME"
)
for tex_input in "${texmf_verify_files[@]}"; do
  latex_vm_args+=(--verify-tex "$tex_input")
done

exec "$SCRIPT_DIR/latex-vm.sh" "${latex_vm_args[@]}"
