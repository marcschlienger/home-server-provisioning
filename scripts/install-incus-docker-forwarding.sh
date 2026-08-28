#!/usr/bin/env bash
# Install the persistent Docker/Incus forwarding integration on the host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if (( EUID != 0 )); then
  echo "ERROR: run this installer as root:" >&2
  echo "       sudo ./scripts/install-incus-docker-forwarding.sh" >&2
  exit 1
fi

command -v iptables >/dev/null 2>&1 \
  || { echo "ERROR: iptables is required." >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 \
  || { echo "ERROR: systemd is required." >&2; exit 1; }

install -m 0755 \
  "$ROOT_DIR/systemd/incus-docker-forward" \
  /usr/local/sbin/incus-docker-forward
install -m 0644 \
  "$ROOT_DIR/systemd/incus-docker-forward.service" \
  /etc/systemd/system/incus-docker-forward.service

systemctl daemon-reload
systemctl enable incus-docker-forward.service
systemctl restart incus-docker-forward.service

echo "==> Persistent Incus forwarding installed."
iptables -S DOCKER-USER
