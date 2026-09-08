#!/usr/bin/env bash
# Step 3 – clone the working set and install the agent config. Runs as dan on the box.
# Needs: `gh auth login` first – cloning goes through gh, so its HTTPS token is
# enough and no SSH key needs to reach the box.
set -euo pipefail

GH_USER="${GH_USER:-dhpwd}"
command -v gh >/dev/null || { echo "gh not installed – run 01-base.sh first" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run 'gh auth login' first" >&2; exit 1; }
WORKSPACE="$HOME/Workspace"
mkdir -p "$WORKSPACE"

# Every repo agents read across, as <local dir>=<github owner/repo>. The local
# directory need not match the repo name – two of mine differ, which is why
# cloning by directory name found nothing the first time. Keep this list in
# step with ~/Workspace on the laptop. Mine has thirteen entries; these two are
# placeholders.
REPOS=(
  "cloud-box=dhpwd/cloud-box"
  "danhopwood.com=dhpwd/danhopwood.com"
)

# Anything on the laptop with no git remote is outside the git-backed rule the
# laptop is meant to follow. Copy it across deliberately or leave it behind.

# .git/hooks never travels with a clone, so pre-commit's hook has to be installed
# per repo on this machine. The template directory covers anything cloned later,
# including repos added to ~/Workspace without touching this script.
command -v pre-commit >/dev/null || uv tool install pre-commit
git config --global init.templateDir "$HOME/.git-template"
pre-commit init-templatedir "$HOME/.git-template" >/dev/null

for entry in "${REPOS[@]}"; do
  dir="${entry%%=*}"
  slug="${entry#*=}"
  if [ -d "$WORKSPACE/$dir/.git" ]; then
    echo "==> $dir exists, pulling"
    git -C "$WORKSPACE/$dir" pull --ff-only || echo "    (skipped – not fast-forwardable)"
  else
    echo "==> cloning $slug into $dir"
    gh repo clone "$slug" "$WORKSPACE/$dir" || echo "    !! failed: $slug"
  fi
  # Installs whatever hooks the repo's own config lists. Without this only the
  # repo this script happened to `cd` into last got a hook at all, and the rest
  # committed unformatted on this box for days. Matches the laptop.
  [ -f "$WORKSPACE/$dir/.pre-commit-config.yaml" ] &&
    (cd "$WORKSPACE/$dir" && pre-commit install >/dev/null)
  # Dependencies, with the manager the lockfile names – npm, pnpm or bun –
  # so the lockfile is never
  # rewritten and `sweep` stays clean. Frozen installs fail rather than
  # resolve afresh when package.json and the lockfile disagree. Runs on
  # every pass, so re-running this script after a pull picks up a changed
  # lockfile. Without this, an agent that hits a missing module installs
  # with whatever manager it reaches for, which can mean npm against a bun
  # lockfile.
  (cd "$WORKSPACE/$dir" && {
    if [ -f bun.lock ] || [ -f bun.lockb ]; then bun install --frozen-lockfile
    elif [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile
    elif [ -f package-lock.json ]; then npm ci
    fi
  }) || echo "    !! dependency install failed: $dir"
done

echo "==> Installing agent config"
# My dotfiles repo has an install.sh that reproduces ~/.claude and friends and
# wires shell/gitconfig, shell/gitignore and shell/starship.toml from this repo
# into the global git config and ~/.config. Point DOTFILES at yours.
DOTFILES="${DOTFILES:-$WORKSPACE/cli-agents}"
if [ -x "$DOTFILES/install.sh" ]; then
  (cd "$DOTFILES" && ./install.sh)
else
  echo "    !! no install.sh at $DOTFILES – install your agent config by hand"
fi

echo "==> Done. Next: 04-mcp.sh"
