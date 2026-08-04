#!/usr/bin/env bash
# =============================================================================
# build-images.sh — builds ubuntu-base, ubuntu-latex, and ubuntu-agents images
# in sequence. Each step publishes to local: so the next step can use it.
#
# Usage:
#   ./build-images.sh                # build all three (base → latex → agents)
#   ./build-images.sh --only base    # rebuild only base
#   ./build-images.sh --only latex   # rebuild only latex (requires base)
#   ./build-images.sh --only agents  # rebuild only agents (requires base)
#
# Expected runtime: base ~10 min, latex ~30-40 min, agents ~5 min.
#
# Re-runs publish the new image to a temporary alias (<name>-new), then promote
# it to the canonical alias only AFTER the publish succeeds. If promotion fails,
# the script recreates the previous alias when possible.
# Old image data remains as orphan fingerprints until you delete it manually
# (see `incus image list local:`).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config "$ROOT_DIR/config.env"

CLOUD_INIT_DIR="$ROOT_DIR/cloud-init"
TIMESTAMP=$(date +%s)
ONLY=""

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "==> $*"; }
info() { echo "    $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) require_value --only "${2:-}" || exit 2
            ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── Input validation ──────────────────────────────────────────────────────────
command -v incus >/dev/null 2>&1 || die "incus CLI not found in PATH."
[[ -n "${UBUNTU_REMOTE:-}" ]]    || die "UBUNTU_REMOTE not set in config.env."
[[ -n "${BASE_IMAGE:-}"    ]]    || die "BASE_IMAGE not set in config.env."

# ── Image alias helpers ───────────────────────────────────────────────────────
alias_exists() {
  local alias_short="$1"
  incus image alias list -f csv 2>/dev/null \
    | cut -d, -f1 \
    | grep -qx "$alias_short"
}

alias_fingerprint() {
  local alias_short="$1"
  incus image alias list -f csv 2>/dev/null \
    | awk -F, -v alias="$alias_short" '$1 == alias { print $2; exit }'
}

# ── Core build + publish routine ──────────────────────────────────────────────
build_and_publish() {
  local instance="$1"
  local alias="$2"
  local cloud_init_file="$3"
  local source_image="$4"
  local disk_size="$5"

  [[ -f "$cloud_init_file" ]] || die "Missing cloud-init file: $cloud_init_file"

  step "Launching build instance: $instance (from $source_image)"
  incus launch "$source_image" "$instance" \
    --vm \
    --config limits.cpu=4 \
    --config limits.memory=4GiB \
    --device "root,size=${disk_size}" \
    --config "user.user-data=$(cat "$cloud_init_file")"

  info "Waiting for VM to become reachable..."
  wait_for_instance "$instance" 600 || die "VM never became reachable."
  info "VM is up. Waiting for cloud-init to finish (may take 20-40 min for latex)..."
  wait_for_cloud_init "$instance"   || die "cloud-init failed; see log above."

  info "Cleaning cloud-init state for a clean snapshot..."
  incus exec "$instance" -- cloud-init clean --logs

  info "Stopping instance..."
  incus stop "$instance" --force

  # Publish to a temp alias FIRST so a failure here leaves the previous good
  # alias intact. Only after publish succeeds do we swap the canonical alias.
  local alias_short="${alias##local:}"
  local temp_alias="${alias_short}-new"
  local previous_fingerprint=""

  # Clean any leftover temp from a previous failed run (best-effort).
  incus image alias delete "$temp_alias" 2>/dev/null || true

  info "Publishing to temporary alias: $temp_alias"
  incus publish "$instance" --alias "$temp_alias"

  # Swap: drop old canonical alias (if present), then rename temp to canonical.
  # If the rename fails after the delete, restore the old alias when possible.
  if alias_exists "$alias_short"; then
    previous_fingerprint=$(alias_fingerprint "$alias_short")
    info "Removing previous alias: $alias_short"
    incus image alias delete "$alias_short"
  fi
  info "Promoting $temp_alias -> $alias_short"
  if ! incus image alias rename "$temp_alias" "$alias_short"; then
    if [[ -n "$previous_fingerprint" ]]; then
      info "Promotion failed; restoring $alias_short -> $previous_fingerprint"
      incus image alias create "$alias_short" "$previous_fingerprint" || true
    fi
    die "Could not promote $temp_alias to $alias_short."
  fi

  info "Deleting build instance..."
  incus delete "$instance"

  info "Done: $alias  (run 'incus image list local:' to see; old image data" \
       "remains as orphan fingerprint until you 'incus image delete' it)"
}

# ── Sanity check for derived builds ───────────────────────────────────────────
need_base() {
  incus image info "$BASE_IMAGE" &>/dev/null \
    || die "$BASE_IMAGE not found. Build it first: ./build-images.sh --only base"
}

# ── Build sequence ────────────────────────────────────────────────────────────
case "$ONLY" in
  ""|"all")
    build_and_publish "build-base-$TIMESTAMP"   "$BASE_IMAGE"   \
      "$CLOUD_INIT_DIR/build-base.yaml"   "$UBUNTU_REMOTE" "30GiB"

    step "Building LaTeX image — texlive-full takes 20-40 min, please be patient."
    build_and_publish "build-latex-$TIMESTAMP"  "$LATEX_IMAGE"  \
      "$CLOUD_INIT_DIR/build-latex.yaml"  "$BASE_IMAGE"    "60GiB"

    build_and_publish "build-agents-$TIMESTAMP" "$AGENTS_IMAGE" \
      "$CLOUD_INIT_DIR/build-agents.yaml" "$BASE_IMAGE"    "30GiB"
    ;;

  "base")
    build_and_publish "build-base-$TIMESTAMP" "$BASE_IMAGE" \
      "$CLOUD_INIT_DIR/build-base.yaml" "$UBUNTU_REMOTE" "30GiB"
    ;;

  "latex")
    need_base
    step "Building LaTeX image — texlive-full takes 20-40 min, please be patient."
    build_and_publish "build-latex-$TIMESTAMP" "$LATEX_IMAGE" \
      "$CLOUD_INIT_DIR/build-latex.yaml" "$BASE_IMAGE" "60GiB"
    ;;

  "agents")
    need_base
    build_and_publish "build-agents-$TIMESTAMP" "$AGENTS_IMAGE" \
      "$CLOUD_INIT_DIR/build-agents.yaml" "$BASE_IMAGE" "30GiB"
    ;;

  *)
    die "Unknown --only target: '$ONLY' (expected: base | latex | agents | all)"
    ;;
esac

step "Image build complete. Current local images:"
incus image list local: --format table
