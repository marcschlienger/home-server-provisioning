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
#
# Placeholders substituted by the launch scripts before launch:
#   __DOTFILES_REPO__    git URL of dotfiles repo (may be empty)
#   __INSTALL_CMD__      command to apply dotfiles (default: stow .)
# =============================================================================

runcmd:
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
  - sudo -u admin env HOME=/home/admin bash -c
      'if [ ! -x "$HOME/.local/bin/uv" ]; then curl -LsSf https://astral.sh/uv/install.sh | sh; fi'

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
  - command -v claude && command -v codex && command -v pi

final_message: "Launch-init complete."
