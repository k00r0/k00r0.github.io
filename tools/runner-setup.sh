#!/usr/bin/env bash
# Turns a free Oracle Cloud server (Ubuntu 24.04, ARM) into a GitHub Actions runner,
# so workflows run here instead of using GitHub's monthly minutes.
#
# Run it once per private repo:
#   curl -fsSL https://k00r0.github.io/tools/runner-setup.sh -o runner-setup.sh && bash runner-setup.sh
# It asks for the repo (e.g. k00r0/gita-shorts) and a one-hour registration token from
# GitHub: repo -> Settings -> Actions -> Runners -> New self-hosted runner (copy only the
# value after --token). The token is typed here, never into a chat.
#
# Never attach this server to a PUBLIC repo: anyone could run code on it through a pull request.
set -euo pipefail

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mStopped: %s\033[0m\n' "$*"; exit 1; }

command -v apt-get >/dev/null || die "this needs an Ubuntu server (create the instance with the Ubuntu 24.04 image)."
[ "$(id -u)" -ne 0 ] || die "run it as the normal 'ubuntu' user, not root."

case "$(uname -m)" in
  aarch64|arm64) ARCH=arm64 ;;
  x86_64) ARCH=x64 ;;
  *) die "unknown CPU type $(uname -m)" ;;
esac

read -rp "GitHub repo (owner/name, e.g. k00r0/gita-shorts): " REPO
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "that doesn't look like owner/name."
read -rsp "Registration token (hidden while you paste): " TOKEN; echo
[ -n "$TOKEN" ] || die "no token given."
NAME="${REPO#*/}"
DIR="/opt/actions-runner/$NAME"

if [ ! -f /etc/gh-runner-base-done ]; then
  say "Installing the basics (5-10 minutes the first time)"
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    git curl jq unzip zip ffmpeg python3 python3-venv python3-pip \
    libraqm0 libfribidi0 libharfbuzz0b build-essential ca-certificates

  if ! swapon --show | grep -q swap; then
    say "Adding 4 GB of swap (safety net for video rendering)"
    sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  fi

  if ! id runner >/dev/null 2>&1; then
    say "Creating a 'runner' user for the jobs"
    sudo useradd -m -s /bin/bash runner
    echo 'runner ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/runner >/dev/null
    sudo chmod 440 /etc/sudoers.d/runner
  fi
  sudo touch /etc/gh-runner-base-done
fi

say "Downloading the GitHub runner"
VER=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
[ -n "$VER" ] && [ "$VER" != null ] || die "couldn't find the latest runner version (network?)."
if [ -f "$DIR/.runner" ]; then
  say "A runner for $REPO already exists here; replacing it"
  sudo bash -c "cd '$DIR' && (./svc.sh stop; ./svc.sh uninstall) >/dev/null 2>&1 || true"
  sudo rm -rf "$DIR"
fi
sudo mkdir -p "$DIR" && sudo chown runner:runner "$DIR"
sudo -u runner bash -c "cd '$DIR' && curl -fsSL -o r.tgz https://github.com/actions/runner/releases/download/v$VER/actions-runner-linux-$ARCH-$VER.tar.gz && tar xzf r.tgz && rm r.tgz"
sudo bash -c "cd '$DIR' && ./bin/installdependencies.sh" >/dev/null

say "Connecting to $REPO"
sudo -u runner bash -c "cd '$DIR' && ./config.sh --unattended --replace \
  --url 'https://github.com/$REPO' --token '$TOKEN' \
  --name 'oracle-$NAME' --labels oracle --work _work"

say "Starting it as a service (it restarts by itself after a reboot)"
sudo bash -c "cd '$DIR' && ./svc.sh install runner && ./svc.sh start" >/dev/null

say "Done. In GitHub: $REPO -> Settings -> Actions -> Runners should show 'oracle-$NAME' as Idle (green)."
