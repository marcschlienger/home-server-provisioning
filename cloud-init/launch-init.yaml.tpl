#cloud-config
# =============================================================================
# Launch-time init for LaTeX and agent VMs — injected per-instance at launch
# (NOT baked into images).
#
# These VMs are reached from the HOST only: via `incus exec`, or via SSH to
# their incusbr0-local IP (host-private, NOT exposed to LAN or internet).
# No Tailscale is installed or used here.
#
# Handles first-boot concerns:
#   1. Ensure the fixed admin VM login user exists
#   2. Enable password SSH for that user (admin/admin)
#   3. Clone + apply dotfiles
#   4. Restore Pi's npm-generated launcher if it is absent on first boot
#
# Placeholders substituted by the launch scripts before launch:
#   __DOTFILES_REPO__    git URL of dotfiles repo (may be empty)
#   __INSTALL_CMD__      command to apply dotfiles (default: stow .)
# =============================================================================

# The Ubuntu default user is renamed to admin during scripts-user. The next
# cloud-init module would otherwise try to inspect the now-absent ubuntu user.
# These VMs provision no authorized SSH keys, so fingerprint logging is unused.
no_ssh_fingerprints: true

write_files:
  # Pi's package survives the image lifecycle, but its npm-generated bin link
  # can be absent in a newly launched VM. Recreate it from the installed
  # package metadata; this is deterministic and needs no network reinstall.
  - path: /usr/local/sbin/repair-pi-launcher
    permissions: '0755'
    content: |
      #!/bin/sh
      set -eu

      [ -x /usr/local/bin/pi ] && exit 0

      package_dir=/usr/local/lib/node_modules/@earendil-works/pi-coding-agent
      package_json=$package_dir/package.json
      if [ ! -f "$package_json" ]; then
        echo "ERROR: Pi package is missing: $package_json" >&2
        exit 1
      fi

      entry=$(
        node - "$package_json" <<'NODE'
      const fs = require("node:fs");
      const pkg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
      const entry = typeof pkg.bin === "string" ? pkg.bin : pkg.bin?.pi;
      if (typeof entry !== "string" || entry.length === 0) process.exit(1);
      process.stdout.write(entry);
      NODE
      )

      target=$(readlink -f "$package_dir/$entry")
      case "$target" in
        "$package_dir"/*) ;;
        *) echo "ERROR: invalid Pi entry point: $entry" >&2; exit 1 ;;
      esac
      if [ ! -x "$target" ]; then
        echo "ERROR: Pi entry point is missing or not executable: $target" >&2
        exit 1
      fi

      mkdir -p /usr/local/bin
      ln -sfn "$target" /usr/local/bin/pi

runcmd:
  - set -e

  # ── VM login user ───────────────────────────────────────────────────────────
  - if ! getent group admin >/dev/null 2>&1; then
      if id ubuntu >/dev/null 2>&1 && getent group ubuntu >/dev/null 2>&1; then
        groupmod -n admin ubuntu;
      else
        groupadd admin;
      fi;
    fi
  - if ! id admin >/dev/null 2>&1; then
      if id ubuntu >/dev/null 2>&1; then
        usermod -l admin ubuntu
        && usermod -d /home/admin admin
        && mkdir -p /home/admin
        && if [ -d /home/ubuntu ]; then
             cp -a /home/ubuntu/. /home/admin/ && rm -rf /home/ubuntu;
           fi;
      else
        mkdir -p /home/admin
        && useradd -M -d /home/admin -g admin -s /usr/bin/zsh -G sudo admin;
      fi;
    fi
  - usermod -g admin admin
  - usermod -aG sudo admin
  - if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || userdel ubuntu 2>/dev/null || true; fi
  # Do not recurse: /home/admin/project may already be a host VirtioFS mount.
  - chown admin:admin /home/admin
  - printf 'admin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-vm-user
  - chmod 440 /etc/sudoers.d/90-vm-user
  - chsh -s /usr/bin/zsh admin
  - curl -LsSf https://astral.sh/uv/install.sh -o /run/uv-install.sh
  - chown admin:admin /run/uv-install.sh
  - sudo -u admin env HOME=/home/admin sh /run/uv-install.sh
  - rm -f /run/uv-install.sh
  - test -x /home/admin/.local/bin/uv

  # ── Password SSH for host -> VM access on the private Incus bridge ──────────
  - printf 'admin:%s\n' 'admin' | chpasswd
  - printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' > /etc/ssh/sshd_config.d/99-vm-password.conf
  - systemctl reload ssh || systemctl restart ssh || systemctl reload sshd || systemctl restart sshd

  # ── Dotfiles (skipped if no repo URL) ───────────────────────────────────────
  - if [ -n '__DOTFILES_REPO__' ] && [ ! -d /home/admin/.dotfiles ]; then
      git clone '__DOTFILES_REPO__' /home/admin/.dotfiles
      && chown -R admin:admin /home/admin/.dotfiles
      && sudo -u admin env HOME=/home/admin bash -c
         'cd ~/.dotfiles && __INSTALL_CMD__';
    fi
  - test -d /home/admin/.dotfiles
  - /usr/local/sbin/repair-pi-launcher
  - /usr/local/sbin/verify-agent-clis

final_message: "Launch-init complete."
