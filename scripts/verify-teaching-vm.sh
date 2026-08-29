#!/usr/bin/env bash
# =============================================================================
# verify-teaching-vm.sh — validate teaching mounts, TEXMF discovery, and an
# optional representative LaTeX build in an existing teaching workspace.
#
# Usage:
#   ./verify-teaching-vm.sh [vm-name]
#   ./verify-teaching-vm.sh [vm-name] --tex src:path/to/file.tex
#   ./verify-teaching-vm.sh [vm-name] --tex private:path/to/file.tex
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config "$ROOT_DIR/config.env"

NAME="teaching-ws"
TEX_SPEC=""

if [[ $# -gt 0 && "$1" != --* ]]; then
  NAME="$1"
  shift
fi
validate_name "$NAME" "vm-name"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tex) require_value --tex "${2:-}" || exit 2
           [[ -z "$TEX_SPEC" ]] \
             || { echo "ERROR: --tex may be specified only once." >&2; exit 2; }
           TEX_SPEC="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

for variable_name in \
    TEACHING_SRC_REPO \
    TEACHING_PRIVATE_REPO \
    TEACHING_TEXMF_ROOT \
    TEACHING_TEXMF_VERIFY_FILE; do
  [[ -n "${!variable_name:-}" ]] \
    || { echo "ERROR: $variable_name is not set." >&2; exit 2; }
done

command -v incus >/dev/null 2>&1 || { echo "ERROR: incus CLI not found." >&2; exit 1; }
src_path=$(resolve_git_path "$TEACHING_SRC_REPO" "$GIT_REPOS_ROOT")
private_path=$(resolve_git_path "$TEACHING_PRIVATE_REPO" "$GIT_REPOS_ROOT")
texmf_path=$(resolve_git_path "$TEACHING_TEXMF_ROOT" "$GIT_REPOS_ROOT")

ensure_instance_ready "$NAME" \
  || { echo "ERROR: teaching VM not found: $NAME" >&2; exit 1; }

verify_project_mount "$NAME" "$src_path"
verify_bind_mount "$NAME" "$private_path" /home/admin/repos/teaching-private
verify_bind_mount "$NAME" "$texmf_path" /home/admin/texmf
verify_workspace_bootstrap "$NAME"
verify_tex_input "$NAME" "$TEACHING_TEXMF_VERIFY_FILE"
echo "==> Both teaching repositories and the personal TEXMF tree are visible."

if [[ -z "$TEX_SPEC" ]]; then
  echo "==> Teaching workspace validation passed (no representative build requested)."
  exit 0
fi

case "$TEX_SPEC" in
  src:*) guest_root=/home/admin/project; relative_path=${TEX_SPEC#src:} ;;
  private:*) guest_root=/home/admin/repos/teaching-private; relative_path=${TEX_SPEC#private:} ;;
  *) echo "ERROR: --tex must start with src: or private:." >&2; exit 2 ;;
esac

if [[ -z "$relative_path" \
      || "$relative_path" == /* \
      || "$relative_path" == *$'\n'* \
      || "/$relative_path/" == */../* \
      || "$relative_path" != *.tex ]]; then
  echo "ERROR: --tex must name a relative .tex file without '..': $relative_path" >&2
  exit 2
fi

guest_file="$guest_root/$relative_path"
guest_dir=$(dirname "$guest_file")
tex_name=$(basename "$guest_file")
pdf_name="${tex_name%.tex}.pdf"

incus exec "$NAME" -- test -f "$guest_file" \
  || { echo "ERROR: representative source not found: $guest_file" >&2; exit 1; }

echo "==> Building representative document: $guest_file"
incus exec "$NAME" --cwd "$guest_dir" -- sudo -u admin env HOME=/home/admin \
  latexmk -pdf -interaction=nonstopmode "$tex_name"
incus exec "$NAME" -- test -f "$guest_dir/$pdf_name" \
  || { echo "ERROR: expected PDF was not produced: $guest_dir/$pdf_name" >&2; exit 1; }

echo "==> Representative build passed: $guest_dir/$pdf_name"
