#!/usr/bin/env bash
# Step 4, on the Obsidian route – keeps each vault in VAULTS in two-way sync with
# the owner's Obsidian Sync remote vault, through Obsidian's headless client
# (`ob`), as a systemd user unit, obsidian-sync@<dir>.service, on ~/Workspace/<dir>.
# Runs as the box user, in the owner's box-user session on their own laptop:
# `ob sync-setup` asks there for an end-to-end encrypted vault's password, which
# only the owner types. Safe to run again: it restarts only what changed.
#
# It installs the client and checks the owner's Obsidian sign-in, stopping for
# `ob login` without one. It never passes a password, email or 2FA code to `ob`,
# and never reads `ob`'s stored sign-in or a vault's stored key.
#
# A vault dir also in REPOS is one folder synced both ways: 03-repos.sh clones
# it first, and Obsidian Sync leaves .git alone (it skips names starting with a
# dot, except .obsidian).
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/../scripts/lib.sh"
read_inputs
require_box_user

# The client is an open beta, so it is pinned. To bump it, change this and run
# the script again: it reinstalls the client and restarts every unit.
OBSIDIAN_HEADLESS_VERSION=0.0.14
# The tests set this, so they don't wait.
SETTLE_SECONDS=${OBSIDIAN_SYNC_SETTLE_SECONDS:-20}

if [ ${#VAULT_DIRS[@]} -eq 0 ]; then
  echo "==> VAULTS is empty: no vaults to sync"
  exit 0
fi

[ "$(loginctl show-user "$BOX_USER" --property=Linger --value 2>/dev/null)" = yes ] ||
  die "lingering is off for $BOX_USER, so the syncs would stop at logout. Run 01-base.sh as root, which turns it on."

WORKSPACE="$HOME/Workspace"

# Sync would fill the folder first, and a clone into a folder that isn't empty
# fails.
for dir in "${VAULT_DIRS[@]}"; do
  if in_list "$dir" ${REPO_DIRS[@]+"${REPO_DIRS[@]}"} && [ ! -d "$WORKSPACE/$dir/.git" ]; then
    die "$dir is in REPOS and VAULTS, and $WORKSPACE/$dir isn't cloned yet. Run 03-repos.sh first, then this again."
  fi
done

pin_changed=
if [ "$(ob --version 2>/dev/null || true)" != "$OBSIDIAN_HEADLESS_VERSION" ]; then
  command -v npm >/dev/null || die "npm is not on PATH – run 01-base.sh first"
  echo "==> Installing obsidian-headless $OBSIDIAN_HEADLESS_VERSION"
  npm install -g "obsidian-headless@$OBSIDIAN_HEADLESS_VERSION"
  hash -r
  [ "$(ob --version 2>/dev/null || true)" = "$OBSIDIAN_HEADLESS_VERSION" ] ||
    die "ob --version doesn't print $OBSIDIAN_HEADLESS_VERSION after the install. Check npm's output above"
  pin_changed=1
fi

login_step="Owner's step: run ob login in a box-user session on their own laptop (ssh $BOX_USER@<box name>),
   with the screen share paused, and type the Obsidian email, password and any 2FA code it asks for.
   Then run this again."

# Exits 2 with no stored sign-in. Lists the vaults over the network, so a
# stored sign-in Obsidian refuses fails here too. ob's own message goes to the
# terminal: it holds no credential.
rc=0
remote=$(ob sync-list-remote --json) || rc=$?
case $rc in
  0) ;;
  2) die "Obsidian is not signed in on this box. $login_step" ;;
  *) die "Obsidian refused the stored sign-in, or couldn't be reached (ob's message is above). $login_step" ;;
esac
jq -e '.vaults | type == "array"' <<<"$remote" >/dev/null 2>&1 || die "ob sync-list-remote --json printed something that isn't its vault list"

# Each VAULTS entry's remote part, as an ID first, else as the one vault of
# that name, among the vaults the account owns and those shared with it.
VAULT_IDS=()
VAULT_NAMES=()
for i in "${!VAULT_DIRS[@]}"; do
  dir=${VAULT_DIRS[$i]}
  want=${VAULT_REMOTES[$i]}
  matches=$(jq -r --arg w "$want" '
    ((.vaults // []) + (.shared // [])) as $all
    | ([$all[] | select(.id == $w)] | if length > 0 then . else [$all[] | select(.name == $w)] end)
    | .[] | "\(.id)\t\(.name)"' <<<"$remote")
  if [ -z "$matches" ]; then
    echo "!! VAULTS entry for $dir: no remote vault in this Obsidian account has the ID or name '$want'. Its vaults:" >&2
    jq -r '((.vaults // []) + (.shared // []))[] | "!!   \(.name)"' <<<"$remote" >&2
    die "Fix the name in VAULTS, then run this again."
  fi
  if [ "$(wc -l <<<"$matches")" -gt 1 ]; then
    echo "!! VAULTS entry for $dir: '$want' names more than one remote vault. Their IDs:" >&2
    cut -f1 <<<"$matches" | sed 's/^/!!   /' >&2
    die "Put the ID of the one to sync in VAULTS in place of the name, then run this again."
  fi
  VAULT_IDS+=("${matches%%$'\t'*}")
  VAULT_NAMES+=("${matches#*$'\t'}")
done

# ob keeps one link per remote vault, so linking a vault that is linked
# elsewhere would move the link and leave the other folder's sync failing.
free_lines() { # the folder to free
  if [ "$(dirname "$1")" = "$WORKSPACE" ]; then
    echo "     systemctl --user disable --now obsidian-sync@$(basename "$1")"
  fi
  echo "     ob sync-unlink --path $1"
}
rc=0
local_links=$(ob sync-list-local --json) || rc=$?
[ "$rc" -eq 0 ] || die "ob sync-list-local failed (its message is above)"
for i in "${!VAULT_DIRS[@]}"; do
  dir=${VAULT_DIRS[$i]}
  id=${VAULT_IDS[$i]}
  name=${VAULT_NAMES[$i]}
  for j in "${!VAULT_DIRS[@]}"; do
    if [ "$j" -lt "$i" ] && [ "${VAULT_IDS[$j]}" = "$id" ]; then
      echo "!! VAULTS entries ${VAULT_DIRS[$j]} and $dir both name the remote vault $name ($id), and a remote vault syncs to one folder." >&2
      echo "   Keep one of them in VAULTS." >&2
      linked=$(jq -r --arg id "$id" '.vaults[] | select(.id == $id) | .path' <<<"$local_links")
      if [ -n "$linked" ]; then
        echo "   It is linked to $linked now. If that is the one you drop, free it with:" >&2
        free_lines "$linked" >&2
      fi
      die "Then run this again."
    fi
  done
  elsewhere=$(jq -r --arg id "$id" --arg p "$WORKSPACE/$dir" '.vaults[] | select(.id == $id and .path != $p) | .path' <<<"$local_links")
  if [ -n "$elsewhere" ]; then
    echo "!! The remote vault $name ($id) is already linked to $elsewhere, not $WORKSPACE/$dir. To free it:" >&2
    free_lines "$elsewhere" >&2
    die "Then run this again."
  fi
  other=$(jq -r --arg id "$id" --arg p "$WORKSPACE/$dir" '.vaults[] | select(.path == $p and .id != $id) | .id' <<<"$local_links" | head -1)
  if [ -n "$other" ]; then
    other_name=$(jq -r --arg id "$other" '((.vaults // []) + (.shared // []))[] | select(.id == $id) | .name' <<<"$remote" | head -1)
    echo "!! $WORKSPACE/$dir is linked to the remote vault ${other_name:-(not in this account)} ($other), not $name ($id)." >&2
    echo "   This script never unlinks a folder. To link it to $name instead:" >&2
    free_lines "$WORKSPACE/$dir" >&2
    die "Then run this again."
  fi
done

linked_now=()
for i in "${!VAULT_DIRS[@]}"; do
  dir=${VAULT_DIRS[$i]}
  id=${VAULT_IDS[$i]}
  if [ -n "$(jq -r --arg id "$id" --arg p "$WORKSPACE/$dir" '.vaults[] | select(.id == $id and .path == $p) | .id' <<<"$local_links")" ]; then
    echo "==> $dir: linked to ${VAULT_NAMES[$i]}"
    continue
  fi
  echo "==> $dir: linking to ${VAULT_NAMES[$i]} ($id)"
  echo "    An end-to-end encrypted vault asks for its encryption password now. The owner types it, with the screen share paused."
  # In the foreground on this terminal, so ob asks for the password itself.
  ob sync-setup --vault "$id" --path "$WORKSPACE/$dir" --device-name "Cloud box" ||
    die "ob sync-setup for $dir failed (its message is above). Run this again to retry"
  linked_now+=("$dir")
done

units="$HOME/.config/systemd/user"
mkdir -p "$units"
# bash -lc, because nvm's Node reaches PATH only through ~/.profile.
unit_text=$(
  cat <<'UNIT'
[Unit]
Description=Obsidian Sync for ~/Workspace/%i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'exec ob sync --continuous --path %h/Workspace/%i'
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
UNIT
)
unit_changed=
if [ "$(cat "$units/obsidian-sync@.service" 2>/dev/null)" != "$unit_text" ]; then
  printf '%s\n' "$unit_text" >"$units/obsidian-sync@.service"
  systemctl --user daemon-reload
  unit_changed=1
fi

started=
for dir in "${VAULT_DIRS[@]}"; do
  unit="obsidian-sync@$dir.service"
  systemctl --user enable --quiet "$unit"
  why=
  if [ -n "$pin_changed" ]; then why="the client was installed"
  elif [ -n "$unit_changed" ]; then why="the unit file changed"
  elif in_list "$dir" ${linked_now[@]+"${linked_now[@]}"}; then why="just linked"
  elif ! systemctl --user is-active --quiet "$unit"; then why="not running"
  fi
  if [ -z "$why" ]; then
    echo "==> $dir: running, unchanged"
    continue
  fi
  echo "==> $dir: $why – (re)starting its sync"
  systemctl --user restart "$unit"
  started=1
done

while read -r u _; do
  d=${u#obsidian-sync@}
  d=${d%.service}
  in_list "$d" "${VAULT_DIRS[@]}" ||
    echo "    note: obsidian-sync@$d is set up but not in VAULTS, and an enabled one starts again at boot. To remove it: systemctl --user disable --now obsidian-sync@$d"
done < <(
  {
    systemctl --user list-units 'obsidian-sync@*' --all --plain --no-legend 2>/dev/null
    for f in "$units"/*.wants/obsidian-sync@*.service; do
      [ ! -L "$f" ] || echo "${f##*/}"
    done
  } | awk '!seen[$1]++'
)

if [ -n "$started" ]; then
  echo "==> Waiting ${SETTLE_SECONDS}s, then checking each sync stayed up"
  sleep "$SETTLE_SECONDS"
fi

down=0
for i in "${!VAULT_DIRS[@]}"; do
  dir=${VAULT_DIRS[$i]}
  unit="obsidian-sync@$dir.service"
  if systemctl --user is-active --quiet "$unit"; then
    echo "    $dir ($WORKSPACE/$dir): ${VAULT_NAMES[$i]}, active"
    continue
  fi
  down=1
  log=$(journalctl --user -u "$unit" -n 30 --no-pager -o cat 2>/dev/null || true)
  echo "!! $dir: not active" >&2
  case $log in
    *"No account logged in"* | *"Failed to authenticate"*)
      echo "   Obsidian is signed out, or refused the stored sign-in. $login_step" >&2
      ;;
    *"subscription to Obsidian Sync has expired"*)
      echo "   Owner's step: the Obsidian Sync subscription has expired. Renew it in Obsidian's account settings, then run this again." >&2
      ;;
    *"no longer exists"*)
      echo "   The remote vault ${VAULT_NAMES[$i]} was deleted or renamed in Obsidian Sync. Fix its entry in VAULTS, then run this again." >&2
      ;;
    *"Encryption key not found"*)
      echo "   The vault's stored encryption key is missing. Unlink it, then run this again and the owner types the encryption password:" >&2
      echo "     ob sync-unlink --path $WORKSPACE/$dir" >&2
      ;;
    *"Another sync instance"*)
      echo "   Another ob sync is running for this vault. Find it with: pgrep -af 'ob sync'" >&2
      ;;
    *)
      echo "   The last lines of its journal:" >&2
      printf '%s\n' "$log" | sed 's/^/     /' >&2
      echo "   Then: ob sync-status --path $WORKSPACE/$dir" >&2
      ;;
  esac
done
[ "$down" -eq 0 ] || exit 1

echo
echo "Obsidian Sync carries no file or folder whose name starts with a dot, except"
echo ".obsidian. Copy each vault's .claude folder once, from the owner's laptop (README, step 5):"
for dir in "${VAULT_DIRS[@]}"; do
  echo "  scp -r <vault on the laptop>/.claude $BOX_USER@<box name>:Workspace/$dir/"
done
echo "Watch a sync: journalctl --user -u obsidian-sync@<dir> -f"
