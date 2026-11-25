#!/usr/bin/env bash
# Step 1 – base system. Runs as root on a fresh Debian 13 (trixie) host, from
# the checkout box.env sits in, before any of the owner's accounts are needed.
# Needs no TTY and is safe to run again.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
read_inputs
require_root

export DEBIAN_FRONTEND=noninteractive

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  arm64|amd64) ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
echo "==> Architecture: $ARCH"

echo "==> Packages"
# Keeps a changed config file rather than asking, which would stop a run with
# no terminal.
apt-get update && apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y
# build-essential and pkg-config: native Node modules and Python source builds
# in an owner's repos need them, and without them the failure only shows as a
# failed install in 03-repos.sh. ufw is installed here, inactive, so the
# lockdown's close doesn't spend its revert window waiting on apt.
apt-get install -y git build-essential pkg-config jq ripgrep sqlite3 zip unzip \
                   ca-certificates curl gnupg rsync sudo ufw

echo "==> Locale"
# SSH forwards LC_* from the client. Without the matching locale generated here,
# everything falls back to C and UTF-8 handling breaks in the TUI.
apt-get install -y locales
grep -q '^en_GB.UTF-8 UTF-8' /etc/locale.gen || echo 'en_GB.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
update-locale LANG=en_GB.UTF-8

echo "==> GitHub CLI"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli.gpg
chmod a+r /etc/apt/keyrings/githubcli.gpg
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y gh

echo "==> User '$BOX_USER'"
# A locked password and no sudo: the agents run as this account, and a password
# set later would otherwise be all it took to use sudo.
if ! id "$BOX_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$BOX_USER"
fi
privileged=$(id -nG "$BOX_USER" | tr ' ' '\n' | grep -xE 'sudo|wheel|root|disk|docker|lxd|incus|incus-admin|shadow|staff' | tr '\n' ' ' || true)
[ -z "$privileged" ] || die "$BOX_USER is in: ${privileged% }. The agents run as this account, so it must have no admin rights. Remove each with: gpasswd -d $BOX_USER <group>, or choose another BOX_USER. Then run this again"

echo "==> Operator's key for $BOX_USER"
# A real SSH sign-in as the box user is how the operator gets a working
# systemctl --user session for the later steps.
grant_operator_key

echo "==> Lingering"
# Without it the user's systemd manager stops at logout, and the Remote Control
# servers with it.
loginctl enable-linger "$BOX_USER"

echo "==> Public SSH: keys only"
# sshd keeps the first value it reads for each keyword, and Debian includes the
# drop-ins in name order before the rest of sshd_config, so this file's name
# must sort before any drop-in the image ships. PermitRootLogin is left out on
# purpose: 99-tailscale.conf's "no" has to be the first value read.
cat > "$SSHD_CONFIG_D/00-cloud-box-key-only.conf" <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF
sshd -t
systemctl reload ssh
echo "    effective settings:"
print_sshd_settings root "$BOX_USER"
require_sshd_key_only root "$BOX_USER"

echo "==> Unattended security upgrades"
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
# The timers do the upgrading. unattended-upgrades.service is only the hook
# that finishes an upgrade at shutdown.
systemctl enable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer

echo "==> Runtimes and Claude Code (as $BOX_USER)"
sudo -u "$BOX_USER" -i bash <<'USERSETUP'
set -euo pipefail

grep -q 'HOME/.local/bin' ~/.profile || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile

# Node via nvm. The installer only writes to ~/.bashrc, so anything that
# needs node from a non-bash login shell (systemd units) must source nvm itself.
# The default is pinned rather than lts/*: global packages live per Node
# version, so a default that follows the newest LTS moves the moment any repo
# installs a newer one, and every new shell loses the global tools below. Bump
# it deliberately, carrying the globals across in the same step:
#   nvm install <ver> --reinstall-packages-from=default && nvm alias default <ver>
NODE_VER=24.22.1
export NVM_DIR="$HOME/.nvm"
[ -d "$NVM_DIR" ] || curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_VER"
# Only when no default is set yet, so a deliberate bump survives a re-run.
[ "$(nvm version default)" != N/A ] || nvm alias default "$NODE_VER"

# Make nvm available to login shells that read ~/.profile as well as ~/.bashrc.
grep -q 'NVM_DIR' ~/.profile || cat >> ~/.profile <<'PROF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
PROF

# Python + uv, then pre-commit, which 03-repos.sh installs per repo.
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv tool install pre-commit

# pnpm and bun, for repos whose lockfiles are not npm's. 03-repos.sh installs
# each repo's dependencies with the manager its lockfile names, so both must
# exist before it runs. bun's installer lands in ~/.bun and edits ~/.bashrc
# only, so ~/.profile gets the PATH line for login shells as well.
npm i -g pnpm
curl -fsSL https://bun.sh/install | bash
grep -q '\.bun/bin' ~/.profile || echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.profile

# The native installer, not npm: an npm install blocks Claude Code's own
# postinstall scripts, and /login then fails. It lands in ~/.local/bin and
# updates itself from then on.
[ -x "$HOME/.local/bin/claude" ] || curl -fsSL https://claude.ai/install.sh | bash
"$HOME/.local/bin/claude" --version
USERSETUP

echo "==> Done. Next: 02-tailscale-lockdown.sh up"
