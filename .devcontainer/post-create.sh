#!/bin/bash
set -euo pipefail

echo "=== AI Observability Workshop Setup ==="

# ─── Initialize git submodules ───────────────────────────────────────
echo "Initializing git submodules (dtctl, dynatrace-skills)..."
git submodule update --init --recursive

# ─── Install dtctl ───────────────────────────────────────────────────
echo "Installing dtctl..."
export DTCTL_INSTALL_DIR="/usr/local/bin"
sh dtctl/install.sh

# ─── Install dynatrace-skills (symlink for agent access) ────────────
echo "Setting up dynatrace-skills..."
if [ -d "dynatrace-skills/skills" ]; then
  echo "  dynatrace-skills submodule ready."
fi

# Install k3d
echo "Installing k3d..."
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Install kustomize
echo "Installing kustomize..."
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/

# Install yq
echo "Installing yq..."
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# Pre-pull message
echo ""
echo "=== Setup Complete ==="
echo "Run 'make up' to create the k3d cluster and deploy all services."
echo "Run 'make down' to tear everything down."
echo ""
