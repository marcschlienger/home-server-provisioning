#!/usr/bin/env bash
# =============================================================================
# validate-cloud-init.sh — sanity-check every cloud-init document.
#
# Two kinds of failure caught:
#   1. YAML parse errors (e.g. the original bug where appended runcmd entries
#      landed past `final_message`).
#   2. Unresolved placeholders — any literal __SOMETHING__ remaining in a
#      generated file means a substitution was forgotten.
#
# Three passes:
#   A. Parse every checked-in cloud-init file as-is.
#   B. Render every launch template with sample values + parse + scan.
#   C. Render every launch template with the DEFAULT config.env values
#      (catches issues like an unedited placeholder DOTFILES_REPO being
#      embedded verbatim into a generated clone command).
#
# Requires Python3 + PyYAML (`sudo apt install python3-yaml`).
#
# Usage:
#   ./scripts/validate-cloud-init.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

CI_DIR="$ROOT_DIR/cloud-init"
FAIL=0
PASS=0

die() { echo "ERROR: $*" >&2; exit 1; }

# Pick a YAML parser. Prefer Python3+PyYAML; fall back to ruby.
parse_yaml() {
  local file="$1"
  if command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys, yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "$file"
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0]))' "$file"
  else
    die "Need python3+PyYAML (sudo apt install python3-yaml) or ruby to parse YAML."
  fi
}

check_yaml() {
  local label="$1"
  local file="$2"
  if parse_yaml "$file" 2>/dev/null; then
    echo "  PASS  $label  (YAML parses)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label  (YAML parse error)"
    echo "        --- contents (first 40 lines) ---"
    sed 's/^/        /' "$file" | head -40
    echo "        --- parse error ---"
    parse_yaml "$file" 2>&1 | sed 's/^/        /' | head -10 || true
    FAIL=$((FAIL + 1))
  fi
}

# Like check_yaml, but DOES NOT print file contents on failure — use for
# generations driven by potentially-secret values (default-config pass).
# The parser error message itself is safe; the file body might contain
# a private dotfiles URL from config.env.local.
check_yaml_quiet() {
  local label="$1"
  local file="$2"
  if parse_yaml "$file" 2>/dev/null; then
    echo "  PASS  $label  (YAML parses)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label  (YAML parse error — file content suppressed)"
    echo "        --- parse error only ---"
    parse_yaml "$file" 2>&1 | sed 's/^/        /' | head -10 || true
    FAIL=$((FAIL + 1))
  fi
}

check_no_placeholders() {
  local label="$1"
  local file="$2"
  local hits
  hits=$(grep -nE '__[A-Z0-9_]+__' "$file" 2>/dev/null || true)
  if [[ -z "$hits" ]]; then
    echo "  PASS  $label  (no unresolved placeholders)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label  (unresolved placeholders):"
    while IFS= read -r line; do
      echo "        $line"
    done <<< "$hits"
    FAIL=$((FAIL + 1))
  fi
}

# ── Pass A: checked-in files (templates intentionally have placeholders, ─────
# so only YAML-parse those; build files should also have no __ markers) ──────
echo "==> Validating checked-in cloud-init files..."
for f in "$CI_DIR"/build-*.yaml; do
  [[ -e "$f" ]] || continue
  check_yaml "$(basename "$f")" "$f"
  check_no_placeholders "$(basename "$f")" "$f"
done

# Templates only get YAML-parsed as-is (placeholders expected).
for f in "$CI_DIR"/launch-*.yaml.tpl; do
  [[ -e "$f" ]] || continue
  check_yaml "$(basename "$f")  (raw template, placeholders OK)" "$f"
done

# ── Pass B: generate with SAMPLE values ──────────────────────────────────────
echo ""
echo "==> Validating GENERATED launch-time cloud-init (sample values)..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

S_DOTFILES_REPO="https://github.com/example/dotfiles.git"
S_INSTALL_CMD="stow ."
S_ADMIN_USER="alice"
S_TS_AUTHKEY="tskey-auth-EXAMPLE-deadbeef1234567890abcdef"
S_TS_HOSTNAME="jupyter-test"

# launch-init.yaml.tpl (LaTeX + agent VMs) — dotfiles and no-dotfiles paths.
# VM login is fixed as admin/admin in the template.
for scenario in full no-dotfiles; do
  local_df="$S_DOTFILES_REPO"
  case "$scenario" in
    no-dotfiles) local_df="" ;;
  esac
  out="$TMPDIR/launch-init.${scenario}.yaml"
  render_template "$CI_DIR/launch-init.yaml.tpl" \
    DOTFILES_REPO="$local_df" \
    INSTALL_CMD="$S_INSTALL_CMD" > "$out"
  check_yaml          "launch-init.yaml.tpl  (sample/$scenario)" "$out"
  check_no_placeholders "launch-init.yaml.tpl  (sample/$scenario)" "$out"
done

# launch-jupyter.yaml.tpl
out="$TMPDIR/launch-jupyter.sample.yaml"
render_template "$CI_DIR/launch-jupyter.yaml.tpl" \
  TS_AUTHKEY="$S_TS_AUTHKEY" \
  TS_HOSTNAME="$S_TS_HOSTNAME" \
  ADMIN_USER="$S_ADMIN_USER" > "$out"
check_yaml          "launch-jupyter.yaml.tpl  (sample)" "$out"
check_no_placeholders "launch-jupyter.yaml.tpl  (sample)" "$out"

# launch-ollama.yaml.tpl
out="$TMPDIR/launch-ollama.sample.yaml"
render_template "$CI_DIR/launch-ollama.yaml.tpl" \
  DOTFILES_REPO="$S_DOTFILES_REPO" \
  INSTALL_CMD="$S_INSTALL_CMD" > "$out"
check_yaml          "launch-ollama.yaml.tpl  (sample)" "$out"
check_no_placeholders "launch-ollama.yaml.tpl  (sample)" "$out"

# ── Pass C: generate with TRACKED-ONLY config.env values ─────────────────────
# IMPORTANT: this pass must NOT source config.env.local. Its purpose is to
# verify that the COMMITTED defaults produce valid cloud-init. Reading the
# .local file would (a) defeat that purpose and (b) pull real secrets into
# temp files; on YAML failure those could leak via printed error output.
echo ""
echo "==> Validating GENERATED launch-time cloud-init (tracked-only config.env)..."

# Capture only config.env values via a subshell.
D_DOTFILES_REPO=""
D_INSTALL_CMD=""
D_JUPYTER_TS_AUTHKEY=""
eval "$(
  set +u
	  # shellcheck source=config.env
	  source "$ROOT_DIR/config.env"
	  printf 'D_DOTFILES_REPO=%q\n'  "${DOTFILES_REPO:-}"
	  printf 'D_INSTALL_CMD=%q\n'    "${DOTFILES_INSTALL_CMD:-stow .}"
	  printf 'D_JUPYTER_TS_AUTHKEY=%q\n' "${JUPYTER_TS_AUTHKEY:-}"
	)"
D_DOTFILES_REPO_EFFECTIVE=$(effective_dotfiles_repo "$D_DOTFILES_REPO")

# Ollama uses effective_dotfiles_repo (placeholder → empty) and must produce
# valid cloud-init even when config.env still has the placeholder.
out="$TMPDIR/launch-ollama.tracked.yaml"
render_template "$CI_DIR/launch-ollama.yaml.tpl" \
  DOTFILES_REPO="$D_DOTFILES_REPO_EFFECTIVE" \
  INSTALL_CMD="$D_INSTALL_CMD" > "$out"
check_yaml_quiet      "launch-ollama.yaml.tpl  (tracked config)" "$out"
check_no_placeholders "launch-ollama.yaml.tpl  (tracked config)" "$out"
# Verify the placeholder URL is actually neutralized.
if grep -q 'YOUR_USERNAME' "$out"; then
  echo "  FAIL  launch-ollama.yaml.tpl  (tracked config) leaks placeholder URL"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  launch-ollama.yaml.tpl  (tracked config) does not leak placeholder URL"
  PASS=$((PASS + 1))
fi

# Jupyter takes no dotfiles; just confirm tracked-equivalent values work.
out="$TMPDIR/launch-jupyter.tracked.yaml"
render_template "$CI_DIR/launch-jupyter.yaml.tpl" \
  TS_AUTHKEY="$D_JUPYTER_TS_AUTHKEY" \
  TS_HOSTNAME="jupyter" \
  ADMIN_USER="admin" > "$out"
check_yaml_quiet      "launch-jupyter.yaml.tpl  (tracked config)" "$out"
check_no_placeholders "launch-jupyter.yaml.tpl  (tracked config)" "$out"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "==> Result: $PASS passed, $FAIL failed."
exit "$FAIL"
