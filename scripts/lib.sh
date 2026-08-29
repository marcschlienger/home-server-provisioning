#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared helpers for launch/build scripts.
# Source with:  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# =============================================================================

# ── Config loading with optional local override ───────────────────────────────
# Sources $1 (typically the tracked config.env), then sources
# "${1}.local" if it exists. The .local file is gitignored and is the
# correct place for local values such as auth keys and the real dotfiles URL.
load_config() {
  local primary="$1"
  [[ -f "$primary" ]] || { echo "ERROR: config file not found: $primary" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$primary"
  if [[ -f "${primary}.local" ]]; then
    # shellcheck disable=SC1090
    source "${primary}.local"
  fi
}

# ── DNS-safe instance name regex ──────────────────────────────────────────────
# Lowercase letters, digits, hyphens. No leading/trailing hyphen. Max 63 chars.
# Safe for Incus instance names and local DNS-style hostnames.
NAME_REGEX='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

# Validate an instance/task name; die on failure.
# Usage:  validate_name "<name>" "<role-for-error-message>"
validate_name() {
  local name="$1"
  local role="${2:-name}"
  [[ "$name" =~ $NAME_REGEX ]] \
    || { echo "ERROR: $role '$name' must be DNS-safe: lowercase, digits, hyphens; no leading/trailing hyphen; ≤63 chars." >&2; exit 2; }
}

# Reject strings that would break the single-quoted bash -c '...' wrappers
# in launch-init templates. Single quote can't appear inside a single-quoted
# string; newlines would break YAML list-item parsing too.
# Usage:  validate_simple_string "<value>" "<label-for-error>"
validate_simple_string() {
  local val="$1"
  local label="${2:-value}"
  if [[ "$val" == *"'"* || "$val" == *$'\n'* ]]; then
    echo "ERROR: $label may not contain single quotes or newlines." >&2
    echo "       Got: $val" >&2
    exit 2
  fi
}

# Validate optional Tailscale auth keys before rendering them into shell
# arguments. Empty is allowed; non-empty values must stay token-like.
# Usage:  validate_tailscale_authkey "<value>" "<label-for-error>"
validate_tailscale_authkey() {
  local val="$1"
  local label="${2:-Tailscale auth key}"
  if [[ -z "$val" ]]; then
    return 0
  fi
  if [[ ! "$val" =~ ^tskey-auth-[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: $label must be empty or look like tskey-auth-... using only letters, digits, underscores, and hyphens." >&2
    exit 2
  fi
}

# Dotfiles are cloned non-interactively during first boot. The VMs receive no
# SSH key or Git credential, so accepting an SSH URL only defers a guaranteed
# authentication failure until cloud-init.
# Usage:  validate_dotfiles_repo <url> <label-for-error>
validate_dotfiles_repo() {
  local val="$1"
  local label="${2:-DOTFILES_REPO}"
  if [[ -z "$val" ]]; then
    return 0
  fi
  if [[ ! "$val" =~ ^https://[^/@]+(/.*)?$ ]]; then
    echo "ERROR: $label must be an anonymously readable https:// URL without embedded credentials." >&2
    echo "       Guest VMs intentionally receive no SSH key or Git credential." >&2
    exit 2
  fi
}

# Escape a string for use as the REPLACEMENT in `sed s|...|REPL|`.
# Handles the | delimiter, &, and backslash. Newlines are not handled
# (validate_simple_string already rejects them upstream).
sed_escape() {
  printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'
}

# Render a template file by substituting __KEY__ placeholders.
# All values are sed-escaped automatically. Pre-validate any values that
# also need to be shell-safe with validate_simple_string.
# Usage:  render_template <template_path> KEY1=VAL1 [KEY2=VAL2 ...]
render_template() {
  local tpl="$1"; shift
  [[ -f "$tpl" ]] || { echo "ERROR: template not found: $tpl" >&2; exit 1; }
  local sed_args=()
  while [[ $# -gt 0 ]]; do
    local pair="$1"
    local key="${pair%%=*}"
    local val="${pair#*=}"
    sed_args+=("-e" "s|__${key}__|$(sed_escape "$val")|g")
    shift
  done
  sed "${sed_args[@]}" "$tpl"
}

# Render a template and fail if any __PLACEHOLDER__ tokens remain.
# Prints only unresolved token names on failure, not rendered user-data.
# Usage:  render_template_checked <template_path> KEY1=VAL1 [KEY2=VAL2 ...]
render_template_checked() {
  local rendered hits
  rendered=$(render_template "$@")
  hits=$(printf '%s\n' "$rendered" | grep -oE '__[A-Z0-9_]+__' | sort -u || true)
  if [[ -n "$hits" ]]; then
    echo "ERROR: rendered template still contains unresolved placeholder(s):" >&2
    while IFS= read -r line; do
      echo "       $line" >&2
    done <<< "$hits"
    exit 2
  fi
  printf '%s\n' "$rendered"
}

# Some scripts read DOTFILES_REPO from config.env. If the user hasn't edited
# it yet, normalize the placeholder to empty so optional-dotfiles workloads
# (Ollama) don't try to clone it. Convert GitHub's common SSH spelling to the
# anonymous HTTPS equivalent for compatibility with older local config files.
# Usage:  effective_dotfiles_repo <raw-value>  → echoes "" or an HTTPS URL
effective_dotfiles_repo() {
  local raw="${1:-}"
  if [[ -z "$raw" || "$raw" == *"YOUR_USERNAME"* ]]; then
    echo ""
  elif [[ "$raw" =~ ^git@github\.com:(.+)$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"
  else
    echo "$raw"
  fi
}

# Resolve --git argument to an absolute host path.
# Bare names resolve under $GIT_REPOS_ROOT; absolute paths are used as-is.
# Echoes the resolved path; exits non-zero with a message if the path
# doesn't exist.
# Usage:  resolve_git_path "<arg>" "<repos_root>"
resolve_git_path() {
  local arg="$1"
  local root="$2"
  local path
  if [[ "$arg" == /* ]]; then
    path="$arg"
  else
    root="${root/#\~/$HOME}"
    [[ "$root" == /* ]] \
      || { echo "ERROR: GIT_REPOS_ROOT must be absolute when --git uses a bare name: $root" >&2; exit 2; }
    path="${root}/${arg}"
  fi
  [[ -d "$path" ]] \
    || { echo "ERROR: project directory not found: $path" >&2; exit 2; }
  realpath -e -- "$path"
}

# Parse a repeatable --mount SOURCE=GUEST_PATH specification. SOURCE follows
# the same rules as --git. Guest paths are deliberately limited to the two
# workspace trees intended for extra repositories and TeX inputs.
# Sets PARSED_MOUNT_SOURCE_ARG and PARSED_MOUNT_TARGET.
# Usage:  parse_mount_spec "<source>=<guest-path>"
parse_mount_spec() {
  local spec="$1"
  [[ "$spec" == *=* ]] \
    || { echo "ERROR: --mount expects SOURCE=GUEST_PATH: $spec" >&2; exit 2; }

  PARSED_MOUNT_SOURCE_ARG="${spec%%=*}"
  PARSED_MOUNT_TARGET="${spec#*=}"
  [[ -n "$PARSED_MOUNT_SOURCE_ARG" && -n "$PARSED_MOUNT_TARGET" ]] \
    || { echo "ERROR: --mount source and guest path must both be non-empty: $spec" >&2; exit 2; }

  if [[ "$PARSED_MOUNT_TARGET" == *[[:space:]]* \
        || "$PARSED_MOUNT_TARGET" == *//* \
        || "$PARSED_MOUNT_TARGET" == */./* \
        || "$PARSED_MOUNT_TARGET" == */../* \
        || "$PARSED_MOUNT_TARGET" == */. \
        || "$PARSED_MOUNT_TARGET" == */.. ]]; then
    echo "ERROR: invalid --mount guest path: $PARSED_MOUNT_TARGET" >&2
    exit 2
  fi

  case "$PARSED_MOUNT_TARGET" in
    /home/admin/repos/* | /home/admin/texmf | /home/admin/texmf/*) ;;
    *)
      echo "ERROR: --mount guest path must be /home/admin/repos/<name>," >&2
      echo "       /home/admin/texmf, or a path below /home/admin/texmf." >&2
      exit 2
      ;;
  esac
}

# Verify an extra disk device on an existing instance by guest path, regardless
# of the device name assigned when the VM was created.
# Usage:  verify_bind_mount <instance> <expected-host-path> <guest-path>
verify_bind_mount() {
  local instance="$1"
  local expected="$2"
  local guest_path="$3"
  local device configured_path configured_source canonical

  while IFS= read -r device; do
    configured_path=$(incus config device get "$instance" "$device" path 2>/dev/null || true)
    [[ "$configured_path" == "$guest_path" ]] || continue

    configured_source=$(incus config device get "$instance" "$device" source 2>/dev/null || true)
    canonical=$(realpath -e -- "$configured_source" 2>/dev/null || true)
    [[ -n "$canonical" ]] \
      || { echo "ERROR: existing instance '$instance' uses an unavailable mount source: $configured_source" >&2; exit 2; }
    [[ "$canonical" == "$expected" ]] \
      || { echo "ERROR: '$guest_path' in '$instance' is mounted from '$canonical', not '$expected'." >&2; exit 2; }
    return 0
  done < <(incus config device list "$instance")

  echo "ERROR: existing instance '$instance' has no mount at '$guest_path'." >&2
  echo "       Extra mounts are fixed when the VM is created; add it while stopped or recreate the VM." >&2
  exit 2
}

# Verify that an existing instance's per-instance `project` device points to
# the requested host path. This prevents a re-entry command from silently
# accepting a different --git value than the one fixed at creation time.
# Usage:  verify_project_mount <instance> <expected-host-path>
verify_project_mount() {
  local instance="$1"
  local expected="$2"
  local configured canonical

  configured=$(incus config device get "$instance" project source 2>/dev/null || true)
  [[ -n "$configured" ]] \
    || { echo "ERROR: existing instance '$instance' has no local 'project' device; --git cannot be applied on re-entry." >&2; exit 2; }

  canonical=$(realpath -e -- "$configured" 2>/dev/null || true)
  [[ -n "$canonical" ]] \
    || { echo "ERROR: existing instance '$instance' uses an unavailable project path: $configured" >&2; exit 2; }
  [[ "$canonical" == "$expected" ]] \
    || { echo "ERROR: existing instance '$instance' is mounted from '$canonical', not requested path '$expected'." >&2; exit 2; }
}

# Wait for an Incus instance to become reachable via `incus exec`.
# Usage:  wait_for_instance <name> [timeout_seconds]
wait_for_instance() {
  local instance="$1"
  local timeout="${2:-300}"
  local started=$SECONDS
  while ! incus exec "$instance" -- true 2>/dev/null; do
    if (( SECONDS - started >= timeout )); then
      echo "ERROR: instance '$instance' did not become reachable within ${timeout}s." >&2
      return 1
    fi
    sleep 5
  done
}

# Wait for cloud-init to finish in a reachable instance.
# Dumps recent cloud-init log on failure.
# Usage:  wait_for_cloud_init <name> [timeout_seconds]
wait_for_cloud_init() {
  local instance="$1"
  local timeout_seconds="${2:-3600}"
  if ! timeout --foreground "$timeout_seconds" \
      incus exec "$instance" -- cloud-init status --wait; then
    echo "" >&2
    echo "ERROR: cloud-init failed or exceeded ${timeout_seconds}s in '$instance'. Recent log:" >&2
    incus exec "$instance" -- tail -n 60 /var/log/cloud-init-output.log >&2 \
      || true
    return 1
  fi
}

# Remove launch-time cloud-init from the Incus instance configuration after a
# successful first boot. This matters most for Jupyter auth keys and also keeps
# one-shot bootstrap data from being exposed indefinitely by `incus config`.
clear_instance_user_data() {
  local instance="$1"
  if ! incus config unset "$instance" user.user-data; then
    echo "WARNING: could not clear launch-time user-data from '$instance'." >&2
  fi
}

# Start or unfreeze an existing instance, then wait until both the guest and
# cloud-init are healthy. Returns 1 only when the instance does not exist.
# Usage: ensure_instance_ready <instance>
ensure_instance_ready() {
  local instance="$1"
  local state

  incus info "$instance" &>/dev/null || return 1
  state=$(incus list -c ns -f csv \
    | awk -F, -v instance="$instance" '$1 == instance { print $2; exit }')
  case "$state" in
    RUNNING)
      ;;
    FROZEN)
      echo "==> Unfreezing existing instance '$instance'..."
      incus unfreeze "$instance"
      ;;
    STOPPED)
      echo "==> Starting existing instance '$instance'..."
      incus start "$instance"
      ;;
    *)
      echo "ERROR: existing instance '$instance' has unexpected state '${state:-unknown}'." >&2
      exit 1
      ;;
  esac
  wait_for_instance "$instance" \
    || { echo "ERROR: could not reach '$instance'." >&2; exit 1; }
  wait_for_cloud_init "$instance" \
    || { echo "ERROR: cloud-init is not healthy in '$instance'; see log above." >&2; exit 1; }
}

# Verify the contract shared by LaTeX and agent workspace VMs. This catches
# old images and previously masked first-boot failures on every re-entry.
verify_workspace_bootstrap() {
  local instance="$1"
  if ! incus exec "$instance" -- test -d /home/admin/.dotfiles; then
    echo "ERROR: '$instance' has no /home/admin/.dotfiles; its first-boot bootstrap is incomplete." >&2
    echo "       Fix DOTFILES_REPO, then recreate this VM." >&2
    return 1
  fi
  if ! incus exec "$instance" -- /usr/local/sbin/verify-agent-clis >/dev/null; then
    echo "ERROR: '$instance' failed the agent CLI contract (Node 22, Claude, Codex, Pi)." >&2
    echo "       Rebuild images for Node/Claude; rerun the instance installers for Codex/Pi." >&2
    return 1
  fi
}

# Persist an explicit TEXMFHOME for POSIX login shells and zsh. This is useful
# when complete TDS repositories are mounted side by side instead of merged.
# Usage: configure_texmf_home <instance> <texmf-home-value>
configure_texmf_home() {
  local instance="$1"
  local texmf_home="${2:-}"

  [[ -n "$texmf_home" ]] || return 0
  if [[ ! "$texmf_home" =~ ^[A-Za-z0-9_./{},:-]+$ ]]; then
    echo "ERROR: TEXMFHOME contains unsupported characters: $texmf_home" >&2
    return 1
  fi

  # The single-quoted program is evaluated by the guest shell, not this one.
  # shellcheck disable=SC2016
  incus exec "$instance" -- sh -c '
    value=$1
    profile=/etc/profile.d/90-workspace-texmf.sh
    printf "export TEXMFHOME=\047%s\047\n" "$value" > "$profile"
    chmod 0644 "$profile"
    if [ -f /etc/zsh/zshenv ] && ! grep -Fqx ". $profile" /etc/zsh/zshenv; then
      printf "\n. %s\n" "$profile" >> /etc/zsh/zshenv
    fi
  ' sh "$texmf_home"
}

# Verify that a TeX input is visible to the fixed workspace user. An explicit
# TEXMFHOME may be supplied for side-by-side complete TDS trees.
# Usage: verify_tex_input <instance> <class-or-style-file> [texmf-home-value]
verify_tex_input() {
  local instance="$1"
  local tex_input="$2"
  local texmf_home="${3:-}"
  local resolved
  local environment=(HOME=/home/admin)

  [[ -n "$tex_input" ]] || return 0
  if [[ ! "$tex_input" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "ERROR: TeX verification input contains unsupported characters: $tex_input" >&2
    return 1
  fi

  [[ -z "$texmf_home" ]] || environment+=(TEXMFHOME="$texmf_home")
  resolved=$(incus exec "$instance" -- sudo -u admin env "${environment[@]}" \
    kpsewhich "$tex_input" 2>/dev/null || true)
  if [[ -z "$resolved" ]]; then
    echo "ERROR: '$tex_input' is not visible in the TeX search path of '$instance'." >&2
    echo "       Check the host TeX trees, their mounts, and TEXMFHOME." >&2
    return 1
  fi
  echo "==> TeX input verified: $tex_input -> $resolved"
}

# Combined wait then enter as the fixed admin VM user. Used after first-run creation.
# Usage:  wait_and_enter <instance> [texmf-home] [tex-input-to-verify]...
wait_and_enter() {
  local instance="$1"
  shift
  local texmf_home="${1:-}"
  (( $# == 0 )) || shift
  echo "==> Waiting for VM to be reachable + cloud-init to finish..."
  wait_for_instance "$instance"   || { echo "ERROR: VM did not become reachable." >&2; exit 1; }
  wait_for_cloud_init "$instance" || { echo "ERROR: cloud-init failed; see log above." >&2; exit 1; }
  verify_workspace_bootstrap "$instance" \
    || { echo "ERROR: workspace bootstrap verification failed." >&2; exit 1; }
  configure_texmf_home "$instance" "$texmf_home" \
    || { echo "ERROR: TEXMFHOME configuration failed." >&2; exit 1; }
  for tex_input in "$@"; do
    verify_tex_input "$instance" "$tex_input" "$texmf_home" \
      || { echo "ERROR: TeX input verification failed." >&2; exit 1; }
  done
  clear_instance_user_data "$instance"
  echo "==> Entering '$instance'..."
  exec incus exec "$instance" -- su - admin
}

# If the instance already exists, start it if needed and exec into it.
# Returns 0 after exec (process replaced), 1 if instance doesn't exist.
# Usage:  reenter_if_exists <name> [texmf-home] [tex-input-to-verify]...
reenter_if_exists() {
  local instance="$1"
  shift
  local texmf_home="${1:-}"
  (( $# == 0 )) || shift
  ensure_instance_ready "$instance" || return 1
  verify_workspace_bootstrap "$instance" \
    || { echo "ERROR: workspace bootstrap verification failed." >&2; exit 1; }
  configure_texmf_home "$instance" "$texmf_home" \
    || { echo "ERROR: TEXMFHOME configuration failed." >&2; exit 1; }
  for tex_input in "$@"; do
    verify_tex_input "$instance" "$tex_input" "$texmf_home" \
      || { echo "ERROR: TeX input verification failed." >&2; exit 1; }
  done
  clear_instance_user_data "$instance"
  echo "==> Entering '$instance'..."
  exec incus exec "$instance" -- su - admin
}

# Validate that a --flag has a usable value (not empty, not another flag).
# Usage in argv loops:  require_value --flag "${2:-}" || exit 2
require_value() {
  local flag="$1"
  local val="${2:-}"
  if [[ -z "$val" || "${val:0:1}" == "-" ]]; then
    echo "ERROR: $flag requires a value" >&2
    return 1
  fi
}

# Warn (don't fail) when the mounted directory itself is not owned by the
# numeric UID/GID used by the image's admin user. The invoking host account is
# irrelevant when a directory belongs to another account or shared group.
# Usage:  warn_if_bind_mount_owner_mismatch <host-path>
warn_if_bind_mount_owner_mismatch() {
  local path="$1"
  local owner
  owner=$(stat -c '%u:%g' -- "$path")
  if [[ "$owner" != "1000:1000" ]]; then
    echo "WARNING: bind-mount root '$path' is owned by ${owner}; the guest 'admin' user is 1000:1000." >&2
    echo "         Access depends on the ownership, modes, and ACLs throughout this tree." >&2
    echo "         See SETUP.md §6 'UID/GID alignment for bind mounts'." >&2
  fi
}
