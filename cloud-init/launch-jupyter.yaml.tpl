#cloud-config
# =============================================================================
# Launch-time init for the JupyterHub system container.
#
# The Jupyter container launches from ubuntu:26.04 directly (NOT from the base
# image, which is a VM image and can't be reused for system containers), so
# Python tooling and optional Tailscale must be installed here.
#
# Placeholders substituted by jupyter-container.sh before launch:
#   __TS_AUTHKEY__    Tailscale auth key (prefer one-time; may be empty)
#   __TS_HOSTNAME__   hostname for Tailscale registration
#   __ADMIN_USER__    first JupyterHub admin user
# =============================================================================

package_update: true
package_upgrade: false

packages:
  - python3
  - python3-dev
  - python3-pip
  - python3-venv
  - curl
  - git

runcmd:
  - set -e

  # Install + bring up Tailscale ONLY if an auth key was provided.
  - if [ -n "__TS_AUTHKEY__" ]; then
      curl -fsSL https://tailscale.com/install.sh -o /run/tailscale-install.sh;
      sh /run/tailscale-install.sh;
      rm -f /run/tailscale-install.sh;
      tailscale up
        --authkey="__TS_AUTHKEY__"
        --hostname="__TS_HOSTNAME__"
        --accept-routes;
    fi

  # Install The Littlest JupyterHub (~10 min on first boot).
  - curl -fsSL https://tljh.jupyter.org/bootstrap.py -o /run/tljh-bootstrap.py
  - sudo python3 /run/tljh-bootstrap.py --admin __ADMIN_USER__
  - rm -f /run/tljh-bootstrap.py

final_message: "Jupyter launch-init complete."
