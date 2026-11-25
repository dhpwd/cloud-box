#!/usr/bin/env bash
# Step 4 – clone the repos in REPOS into ~/Workspace and install their
# dependencies. Runs as the box user, after the owner's GitHub sign-in.
#
#   ./03-repos.sh               # clone what is missing, pull the rest, install
#   ./03-repos.sh --clone-only  # clone and stop before any install
#
# --clone-only is for a repo that needs an env file before its install: an
# install hook can succeed with wrong defaults when the file is missing, so the
# file is copied in between the two runs, not after a failure.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
read_inputs
require_box_user

CLONE_ONLY=
case "${1:-}" in
  "") ;;
  --clone-only) CLONE_ONLY=1 ;;
  *) die "usage: ${0##*/} [--clone-only]" ;;
esac

command -v gh >/dev/null || die "gh is not installed – run 01-base.sh first"
if ! gh auth status >/dev/null 2>&1; then
  die "GitHub is not signed in. Owner's step: run
     gh auth login --hostname github.com --git-protocol https --web
   then enter the code it prints at https://github.com/login/device. Then run this again."
fi
# Lets a session's git push over HTTPS use the owner's GitHub sign-in.
gh auth setup-git

WORKSPACE="$HOME/Workspace"
mkdir -p "$WORKSPACE"

# .git/hooks never travels with a clone, so pre-commit's hook has to be installed
# per repo on this machine. The template directory covers anything cloned later.
command -v pre-commit >/dev/null || uv tool install pre-commit
git config --global init.templateDir "$HOME/.git-template"
pre-commit init-templatedir "$HOME/.git-template" >/dev/null

failed=()
review=()

for i in "${!REPO_DIRS[@]}"; do
  dir=${REPO_DIRS[$i]}
  slug=${REPO_SLUGS[$i]}
  path="$WORKSPACE/$dir"
  if [ -d "$path/.git" ]; then
    echo "==> $dir exists, pulling"
    git -C "$path" pull --ff-only || echo "    !! not fast-forwardable – left as it is"
  else
    echo "==> cloning $slug into $dir"
    if ! gh repo clone "$slug" "$path"; then
      failed+=("$dir: clone of $slug failed")
      continue
    fi
  fi
  [ -z "$CLONE_ONLY" ] || continue

  if [ -f "$path/.pre-commit-config.yaml" ]; then
    (cd "$path" && pre-commit install >/dev/null) || failed+=("$dir: pre-commit install failed")
  fi

  # Frozen installs with the manager the lockfile names, so the lockfile is
  # never rewritten and a package.json that disagrees with it fails here.
  installed=
  node_cmd=()
  if [ -f "$path/bun.lock" ] || [ -f "$path/bun.lockb" ]; then node_cmd=(bun install --frozen-lockfile)
  elif [ -f "$path/pnpm-lock.yaml" ]; then node_cmd=(pnpm install --frozen-lockfile)
  elif [ -f "$path/package-lock.json" ]; then node_cmd=(npm ci)
  fi
  if [ ${#node_cmd[@]} -gt 0 ]; then
    installed=1
    (cd "$path" && "${node_cmd[@]}") || failed+=("$dir: ${node_cmd[*]} failed")
  fi
  if [ -f "$path/uv.lock" ]; then
    installed=1
    (cd "$path" && uv sync --frozen) || failed+=("$dir: uv sync --frozen failed")
  fi
  [ -n "$installed" ] || review+=("$dir")
done

if [ ${#review[@]} -gt 0 ]; then
  echo
  echo "==> Review: no lockfile this script recognises (bun, pnpm, npm, uv). Confirm"
  echo "    nothing needs installing, or install it by hand:"
  printf '    %s\n' "${review[@]}"
fi

if [ ${#failed[@]} -gt 0 ]; then
  echo
  echo "!! Not finished. Fix these, then run this script again:" >&2
  printf '!!   %s\n' "${failed[@]}" >&2
  exit 1
fi

if [ -n "$CLONE_ONLY" ]; then
  echo "==> Cloned. Copy any env file a repo needs before its install, then run ${0##*/} without --clone-only"
else
  echo "==> Done. Next: laptop/push.sh from the owner's laptop (see the README)"
fi
