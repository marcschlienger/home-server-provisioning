#cloud-config
# =============================================================================
# Launch-time init for the Ollama VM.
#
# Launched from BASE_IMAGE. Tailscale is intentionally not installed here.
# Reach the VM from the host with `incus exec`, host-local SSH on incusbr0,
# or later via a reverse proxy if you expose OpenWebUI.
#
# Placeholders substituted by ollama-vm.sh before launch:
#   __DOTFILES_REPO__      optional dotfiles repo (may be empty)
#   __INSTALL_CMD__        dotfiles apply command (e.g. stow */)
# =============================================================================

# The Ubuntu default user is renamed to admin during scripts-user. Disable the
# following authorized-key fingerprint step, which has no keys to report and
# would otherwise look up the now-absent ubuntu user.
no_ssh_fingerprints: true

runcmd:
  - set -e

  # Fixed admin VM login user.
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
  - chown admin:admin /home/admin
  - printf 'admin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-vm-user
  - chmod 440 /etc/sudoers.d/90-vm-user
  - chsh -s /usr/bin/zsh admin
  - curl -LsSf https://astral.sh/uv/install.sh -o /run/uv-install.sh
  - chown admin:admin /run/uv-install.sh
  - sudo -u admin env HOME=/home/admin sh /run/uv-install.sh
  - rm -f /run/uv-install.sh
  - test -x /home/admin/.local/bin/uv

  # Password SSH for host -> VM access on the private Incus bridge.
  - printf 'admin:%s\n' 'admin' | chpasswd
  - printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' > /etc/ssh/sshd_config.d/99-vm-password.conf
  - systemctl reload ssh || systemctl restart ssh || systemctl reload sshd || systemctl restart sshd

  # Optional dotfiles bootstrap.
  # Single-quoted so spaces / & / ? in URLs can't break the command.
  # validate_simple_string upstream rejects single quotes in DOTFILES_REPO.
  - if [ -n '__DOTFILES_REPO__' ]; then
      if [ ! -d /home/admin/.dotfiles ]; then
        git clone '__DOTFILES_REPO__' /home/admin/.dotfiles;
        chown -R admin:admin /home/admin/.dotfiles;
      fi;
      if [ -e /home/admin/.zshrc ] && [ ! -L /home/admin/.zshrc ]; then
        if [ ! -e /home/admin/.zshrc.pre-stow ]; then
          mv /home/admin/.zshrc /home/admin/.zshrc.pre-stow;
          chown admin:admin /home/admin/.zshrc.pre-stow;
        else
          rm -f /home/admin/.zshrc;
        fi;
      fi;
      sudo -u admin env HOME=/home/admin bash -c
        'cd ~/.dotfiles && __INSTALL_CMD__';
    fi

  # Ollama (official installer).
  - curl -fsSL https://ollama.com/install.sh -o /run/ollama-install.sh
  - sh /run/ollama-install.sh && rm -f /run/ollama-install.sh

  # Make Ollama listen on all interfaces so OpenWebUI can reach it.
  - mkdir -p /etc/systemd/system/ollama.service.d
  - printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:11434"\n' > /etc/systemd/system/ollama.service.d/override.conf
  - systemctl daemon-reload
  - systemctl restart ollama

  # Docker for OpenWebUI, installed from Docker's official apt repository.
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - >
    . /etc/os-release
    && printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n'
      "$(dpkg --print-architecture)"
      "${UBUNTU_CODENAME:-$VERSION_CODENAME}"
      > /etc/apt/sources.list.d/docker.list
  - apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # OpenWebUI as a long-running container.
  - >-
    docker run -d --name openwebui --restart=always
    -p 3000:8080
    -e OLLAMA_BASE_URL=http://host.docker.internal:11434
    --add-host=host.docker.internal:host-gateway
    -v openwebui:/app/backend/data
    ghcr.io/open-webui/open-webui:main

final_message: "Ollama launch-init complete."
