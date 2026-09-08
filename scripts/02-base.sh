#!/usr/bin/env bash
# Step 2 – base system. Runs as root on a fresh Debian 13 (trixie) box.
# Needs a TTY for the user password prompt:  ssh -t root@<ip> bash /root/02-base.sh
set -euo pipefail

BOX_USER="${BOX_USER:-dan}"   # the non-root user agents run as

export DEBIAN_FRONTEND=noninteractive

# dpkg's names (arm64, amd64) happen to match what Go, doctl, the apt repos and
# 1Password all use, so one value covers every download below.
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  arm64|amd64) ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
echo "==> Architecture: $ARCH"

echo "==> Packages"
apt update && apt upgrade -y
apt install -y git mosh build-essential jq ripgrep fd-find fzf bat glow micro starship \
               sqlite3 zip unzip \
               xvfb xclip \
               ca-certificates curl gnupg pkg-config rsync sudo \
               libevent-dev libncurses-dev bison autoconf automake

echo "==> Locale"
# SSH forwards LC_* from the client. Without the matching locale generated here,
# everything falls back to C and UTF-8 handling breaks in the TUI.
apt install -y locales
grep -q '^en_GB.UTF-8 UTF-8' /etc/locale.gen || echo 'en_GB.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
update-locale LANG=en_GB.UTF-8

echo "==> tmux 3.7 from source"
# Debian 13 ships 3.5a. Synchronised output (DECSET 2026) landed in 3.7, and without
# it Claude Code's TUI flickers. apt's tmux is removed to avoid two on PATH.
apt remove -y tmux || true
TMUX_VER=3.7
if [ ! -x /usr/local/bin/tmux ]; then
  tmpd=$(mktemp -d)
  curl -fsSL "https://github.com/tmux/tmux/releases/download/${TMUX_VER}/tmux-${TMUX_VER}.tar.gz" \
    | tar -xz -C "$tmpd"
  ( cd "$tmpd/tmux-${TMUX_VER}" && ./configure && make -j"$(nproc)" && make install )
  rm -rf "$tmpd"
fi
/usr/local/bin/tmux -V

echo "==> Go (as root, before dropping to dan – dan's sudo is password-required)"
GO_VER=1.24.0
curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz
rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz

echo "==> Third-party CLIs"
install -m 0755 -d /etc/apt/keyrings

# GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli.gpg
chmod a+r /etc/apt/keyrings/githubcli.gpg
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

# Google Cloud SDK (brings bq and gsutil)
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  > /etc/apt/sources.list.d/google-cloud-sdk.list

# 1Password CLI
curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
  | gpg --dearmor -o /etc/apt/keyrings/1password.gpg
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/1password.gpg] https://downloads.1password.com/linux/debian/$ARCH stable main" \
  > /etc/apt/sources.list.d/1password.list

# Google Chrome. One of my projects drives the real Chrome through
# playwright-core with channel "chrome", which resolves /opt/google/chrome/chrome
# and never falls back to a bundled build - the point is what a visitor's
# browser does with a page. The Playwright MCP's own Chromium is a different
# browser and is not a substitute. Drop this block if nothing you run needs it.
#
# amd64 only: Google publishes no arm64 Linux build. On arm64 the outbound scan
# has no browser and stops naming Chrome, which is the designed failure.
CHROME_PKG=""
if [ "$ARCH" = "amd64" ]; then
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list
  CHROME_PKG="google-chrome-stable"
else
  echo "    !! $ARCH: Google publishes no arm64 Chrome - anything that needs it cannot run here"
fi

apt update
# shellcheck disable=SC2086 # CHROME_PKG is one optional package name or empty
apt install -y gh google-cloud-cli 1password-cli $CHROME_PKG

# doctl ships as a GitHub release tarball, no apt repo
DOCTL_VER=$(curl -fsSL https://api.github.com/repos/digitalocean/doctl/releases/latest | jq -r .tag_name | tr -d v)
curl -fsSL "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VER}/doctl-${DOCTL_VER}-linux-${ARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin doctl

for c in gh gcloud op doctl; do command -v "$c" >/dev/null && echo "    ok $c" || echo "    !! $c missing"; done
if [ -n "$CHROME_PKG" ]; then
  # The path, not just the command: channel "chrome" resolves this exact file.
  [ -x /opt/google/chrome/chrome ] && echo "    ok google-chrome ($(google-chrome --version))" \
    || echo "    !! google-chrome missing from /opt/google/chrome/chrome"
fi

echo "==> User '$BOX_USER'"
if ! id "$BOX_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$BOX_USER"
  usermod -aG sudo "$BOX_USER"
fi

# Sudo stays password-required on purpose: an agent running as $BOX_USER cannot
# escalate. Setting it needs a TTY, so when this runs non-interactively the
# account is left locked and the password is set afterwards.
if [ -t 0 ]; then
  passwd "$BOX_USER"
else
  echo "    !! no TTY – $BOX_USER has no password yet and sudo will not work."
  echo "    !! set it with:  ssh -t root@<ip> passwd $BOX_USER"
  NEEDS_PASSWD=1
fi
rsync --archive --chown="$BOX_USER:$BOX_USER" /root/.ssh "/home/$BOX_USER/"

echo "==> Unattended security upgrades"
apt install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
systemctl enable --now unattended-upgrades

echo "==> Runtimes and per-user tools (as $BOX_USER)"
sudo -u "$BOX_USER" -i bash <<'USERSETUP'
set -euo pipefail

grep -q '/usr/local/go/bin' ~/.profile || \
  echo 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin"' >> ~/.profile

# Node LTS via nvm. The installer only writes to ~/.bashrc, so anything that
# needs node from a non-bash login shell (systemd units) must source nvm itself.
export NVM_DIR="$HOME/.nvm"
[ -d "$NVM_DIR" ] || curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
. "$NVM_DIR/nvm.sh"
nvm install --lts && nvm alias default lts/*

# Make nvm available to login shells that read ~/.profile as well as ~/.bashrc.
grep -q 'NVM_DIR' ~/.profile || cat >> ~/.profile <<'PROF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
PROF

# Python + uv, then pre-commit and hookdeck
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv tool install pre-commit
# prettier is global rather than a devDependency: the pre-commit hook is a
# `language: system` entry that resolves it with `command -v prettier` and exits
# 1 when it is missing, which aborts the commit. Few repos list it in
# package.json, and node_modules/.bin is not on PATH anyway. nvm's global dir is
# reached from ~/.profile, so this is also on PATH for `claude --bg` jobs, whose
# systemd unit runs bash as a login shell.
# vercel is global rather than a per-repo devDependency, because ad-hoc
# use (`vercel logs`, `vercel env pull`, inspecting a deployment) happens in
# repos that deploy through the git integration and have no vercel dep at all.
# Where a repo pins its own, npx and npm scripts still prefer node_modules.
npm i -g hookdeck-cli prettier vercel
# pnpm and bun, for the two repos whose lockfiles are not npm's: danhopwood.com
# (pnpm) and fidero.com (bun). 04-repos.sh installs each repo's dependencies
# with the manager its lockfile names, so both must exist before it runs. bun's
# installer lands in ~/.bun and edits ~/.bashrc only, so ~/.profile gets the
# PATH line for login shells as well, like Go above.
npm i -g pnpm
curl -fsSL https://bun.sh/install | bash
grep -q '\.bun/bin' ~/.profile || echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.profile
USERSETUP

if [ -n "${NEEDS_PASSWD:-}" ]; then
  echo
  echo "==> STILL TO DO: ssh -t root@<ip> passwd $BOX_USER"
fi
echo "==> Done. Next: 03-tailscale-lockdown.sh"
