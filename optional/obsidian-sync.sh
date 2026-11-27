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
# ob takes a sign-in from this ahead of the stored one, and the units never
# have it, so every check here uses the stored sign-in the units use.
session_token=${OBSIDIAN_AUTH_TOKEN:+set}
unset OBSIDIAN_AUTH_TOKEN

WORKSPACE="$HOME/Workspace"
UNITS="$HOME/.config/systemd/user"
# Holds <dir>.started, naming the client version, for each vault whose sync
# has started since its link, the client and the unit file last changed. Each
# of those changes removes the file first (the whole folder for the client or
# the unit file, which also covers a dir whose name starts with a dot), so a
# run that stops before the restart leaves it to the next run. The folder holds
# nothing else.
STARTED="$HOME/.config/obsidian-sync/started"

note_stray_units() {
  local u d f
  while read -r u _; do
    d=${u#obsidian-sync@}
    d=${d%.service}
    in_list "$d" ${VAULT_DIRS[@]+"${VAULT_DIRS[@]}"} ||
      echo "    note: $u is set up but not in VAULTS, and an enabled one starts again at boot. To remove it: systemctl --user disable --now $u"
  done < <(
    {
      systemctl --user list-units 'obsidian-sync@*' --all --plain --no-legend 2>/dev/null
      for f in "$UNITS"/*.wants/obsidian-sync@*.service; do
        [ ! -L "$f" ] || echo "${f##*/}"
      done
    } | awk '!seen[$1]++'
  )
}

if [ ${#VAULT_DIRS[@]} -eq 0 ]; then
  echo "==> VAULTS is empty: no vaults to sync"
  note_stray_units
  exit 0
fi

[ "$(loginctl show-user "$BOX_USER" --property=Linger --value 2>/dev/null)" = yes ] ||
  die "lingering is off for $BOX_USER, so the syncs would stop at logout. Run 01-base.sh as root, which turns it on."

# Sync would fill the folder first, and a clone into a folder that isn't empty
# fails.
for dir in "${VAULT_DIRS[@]}"; do
  if in_list "$dir" ${REPO_DIRS[@]+"${REPO_DIRS[@]}"} && [ ! -d "$WORKSPACE/$dir/.git" ]; then
    die "$dir is in REPOS and VAULTS, and $WORKSPACE/$dir isn't cloned yet. Run 03-repos.sh first, then this again."
  fi
done

ob_is_pinned() { [ "$(ob --version 2>/dev/null || true)" = "$OBSIDIAN_HEADLESS_VERSION" ]; }
if ! ob_is_pinned; then
  command -v npm >/dev/null || die "npm is not on PATH – run 01-base.sh first"
  # A running sync keeps the client it started with.
  rm -rf "$STARTED"
  echo "==> Installing obsidian-headless $OBSIDIAN_HEADLESS_VERSION"
  npm install -g "obsidian-headless@$OBSIDIAN_HEADLESS_VERSION"
  hash -r
  ob_is_pinned || die "ob --version doesn't print $OBSIDIAN_HEADLESS_VERSION after the install. Check npm's output above"
fi

login_step="Owner's step: run ob login in a box-user session on their own laptop (ssh $BOX_USER@<box name>),
   with the screen share paused, and type the Obsidian email, password and any 2FA code it asks for.
   Then run this again."
# ob login checks a stored sign-in before it asks for anything, and stops if
# Obsidian refuses it.
refused_step="After a refusal, the owner runs ob logout first, then ob login. If Obsidian couldn't be reached, run this again once the box is online.
   $login_step"
if [ -n "$session_token" ]; then
  env_note="OBSIDIAN_AUTH_TOKEN is set in this session, and ob login and ob logout would use it in place of the stored sign-in
   the syncs need. Unset it first, and take it out of any login file that sets it."
  login_step="$env_note
   $login_step"
  refused_step="$env_note
   $refused_step"
fi

# Exits 2 with no stored sign-in. Lists the vaults over the network, so a
# stored sign-in Obsidian refuses fails here too. ob's own message goes to the
# terminal: it holds no credential.
rc=0
remote=$(ob sync-list-remote --json) || rc=$?
case $rc in
  0) ;;
  2) die "Obsidian is not signed in on this box. $login_step" ;;
  *) die "Obsidian refused the stored sign-in, or couldn't be reached (ob's message is above). $refused_step" ;;
esac
# The vaults the account owns and those shared with it, as one list.
all_vaults=$(jq -ce '[.vaults[] | .whose = "yours"] + [(.shared // [])[] | .whose = "shared with you"]' <<<"$remote" 2>/dev/null) ||
  die "ob sync-list-remote --json printed something that isn't its vault list"

# Each VAULTS entry's remote part, as an ID first, else as the one vault of
# that name.
VAULT_IDS=()
VAULT_NAMES=()
for i in "${!VAULT_DIRS[@]}"; do
  dir=${VAULT_DIRS[$i]}
  want=${VAULT_REMOTES[$i]}
  matches=$(jq -r --arg w "$want" '
    . as $all
    | ([$all[] | select(.id == $w)] | if length > 0 then . else [$all[] | select(.name == $w)] end)
    | .[] | "\(.id)\t\(.name)"' <<<"$all_vaults")
  if [ -z "$matches" ]; then
    echo "!! VAULTS entry for $dir: no remote vault in this Obsidian account has the ID or name '$want'. Its vaults:" >&2
    jq -r '.[] | "!!   \(.name)"' <<<"$all_vaults" >&2
    die "Fix the name in VAULTS, then run this again."
  fi
  if [ "$(wc -l <<<"$matches")" -gt 1 ]; then
    echo "!! VAULTS entry for $dir: '$want' names more than one remote vault:" >&2
    jq -r --arg w "$want" '.[] | select(.name == $w) | "!!   \(.id)  (\(.whose), region \(.region))"' <<<"$all_vaults" >&2
    die "Put the ID of the one to sync in VAULTS in place of the name, then run this again."
  fi
  VAULT_IDS+=("${matches%%$'\t'*}")
  VAULT_NAMES+=("${matches#*$'\t'}")
done

# ob keeps one link per remote vault, so linking a vault that is linked
# elsewhere would move the link and leave the other folder's sync failing.
free_lines() { # the folder to free
  local d
  d=$(basename "$1")
  if [ "$(dirname "$1")" = "$WORKSPACE" ] && [[ $d =~ ^[A-Za-z0-9._-]+$ && $d != *..* ]]; then
    echo "     systemctl --user disable --now obsidian-sync@$d.service"
  fi
  echo "     ob sync-unlink --path $(printf '%q' "$1")"
}
# Unlinking leaves a folder's notes where they are. The fix this names is a
# new, empty folder rather than moving notes, so nothing ends up inside another
# synced folder or under a running Remote Control session.
merge_warning() { # the folder to free, which holds another vault's notes
  local i
  for i in "${!VAULT_DIRS[@]}"; do
    if [ "$1" = "$WORKSPACE/${VAULT_DIRS[$i]}" ]; then
      echo "   Freed, it still holds that vault's notes, and VAULTS names it for ${VAULT_NAMES[$i]}, so the next run links it there and merges those notes in."
      echo "   To keep them apart, give ${VAULT_NAMES[$i]} a new local dir in VAULTS, which starts empty."
    fi
  done
}
local_links=$(ob sync-list-local --json) || die "ob sync-list-local failed (its message is above)"
# Before the link checks, which would otherwise send the owner to unlink a
# folder that is only one of two entries for the same vault.
for i in "${!VAULT_DIRS[@]}"; do
  for ((j = 0; j < i; j++)); do
    [ "${VAULT_IDS[$j]}" = "${VAULT_IDS[$i]}" ] || continue
    echo "!! VAULTS entries ${VAULT_DIRS[$j]} and ${VAULT_DIRS[$i]} both name the remote vault ${VAULT_NAMES[$i]} (${VAULT_IDS[$i]}), and a remote vault syncs to one folder." >&2
    echo "   Keep one of them in VAULTS." >&2
    linked=$(jq -r --arg id "${VAULT_IDS[$i]}" '.vaults[] | select(.id == $id) | .path' <<<"$local_links")
    if [ -n "$linked" ]; then
      echo "   It is linked to $linked now. If that is the one you drop, free it with:" >&2
      free_lines "$linked" >&2
    fi
    die "Then run this again."
  done
done
for i in "${!VAULT_DIRS[@]}"; do
  dir=${VAULT_DIRS[$i]}
  id=${VAULT_IDS[$i]}
  name=${VAULT_NAMES[$i]}
  elsewhere=$(jq -r --arg id "$id" --arg p "$WORKSPACE/$dir" '.vaults[] | select(.id == $id and .path != $p) | .path' <<<"$local_links")
  if [ -n "$elsewhere" ]; then
    echo "!! The remote vault $name ($id) is already linked to $elsewhere, not $WORKSPACE/$dir. To free it:" >&2
    free_lines "$elsewhere" >&2
    merge_warning "$elsewhere" >&2
    die "Then run this again."
  fi
  other=$(jq -r --arg id "$id" --arg p "$WORKSPACE/$dir" '.vaults[] | select(.path == $p and .id != $id) | .id' <<<"$local_links" | head -1)
  if [ -n "$other" ]; then
    other_name=$(jq -r --arg id "$other" '.[] | select(.id == $id) | .name' <<<"$all_vaults" | head -1)
    echo "!! $WORKSPACE/$dir is linked to the remote vault ${other_name:-(not in this account)} ($other), not $name ($id)." >&2
    echo "   This script never unlinks a folder. To link it to $name instead, free it:" >&2
    free_lines "$WORKSPACE/$dir" >&2
    merge_warning "$WORKSPACE/$dir" >&2
    die "Then run this again."
  fi
done

mkdir -p "$STARTED"
for i in "${!VAULT_DIRS[@]}"; do
  dir=${VAULT_DIRS[$i]}
  id=${VAULT_IDS[$i]}
  if [ -n "$(jq -r --arg id "$id" --arg p "$WORKSPACE/$dir" '.vaults[] | select(.id == $id and .path == $p) | .id' <<<"$local_links")" ]; then
    echo "==> $dir: linked to ${VAULT_NAMES[$i]}"
    continue
  fi
  echo "==> $dir: linking to ${VAULT_NAMES[$i]} ($id)"
  echo "    An end-to-end encrypted vault asks for its encryption password now. The owner types it, with the screen share paused."
  # A sync running on an earlier link of this folder has to restart.
  rm -f "$STARTED/$dir.started"
  # In the foreground on this terminal, so ob asks for the password itself.
  ob sync-setup --vault "$id" --path "$WORKSPACE/$dir" --device-name "Cloud box" ||
    die "ob sync-setup for $dir failed (its message is above). Run this again to retry"
done

mkdir -p "$UNITS"
# bash -lc, because nvm's Node reaches PATH only through ~/.profile. A login
# file could also export OBSIDIAN_AUTH_TOKEN, so the unit clears it and uses
# the stored sign-in this script checked.
unit_text=$(
  cat <<'UNIT'
[Unit]
Description=Obsidian Sync for ~/Workspace/%i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'unset OBSIDIAN_AUTH_TOKEN; exec ob sync --continuous --path %h/Workspace/%i'
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
UNIT
)
if [ "$(cat "$UNITS/obsidian-sync@.service" 2>/dev/null)" != "$unit_text" ]; then
  rm -rf "$STARTED"
  printf '%s\n' "$unit_text" >"$UNITS/obsidian-sync@.service"
  systemctl --user daemon-reload
fi

# A running sync keeps the sign-in it started with, and retries one Obsidian
# refuses without exiting, so a new sign-in reaches it only through a restart.
# The file's time, never its content.
signed_in_at=$(stat -c %Y "${XDG_CONFIG_HOME:-$HOME/.config}/obsidian-headless/auth_token" 2>/dev/null || echo 0)

mkdir -p "$STARTED"
started=
for dir in "${VAULT_DIRS[@]}"; do
  unit="obsidian-sync@$dir.service"
  stamp="$STARTED/$dir.started"
  systemctl --user enable --quiet "$unit"
  why=
  if [ "$(cat "$stamp" 2>/dev/null)" != "$OBSIDIAN_HEADLESS_VERSION" ]; then
    why="it is new, or its link, the client or the unit file changed"
  elif ! systemctl --user is-active --quiet "$unit"; then
    why="it wasn't running"
  else
    since=$(systemctl --user show -p ActiveEnterTimestamp --value --timestamp=unix "$unit")
    since=${since#@}
    [[ $since =~ ^[0-9]+$ ]] || since=0
    # Both times are whole seconds, so a start in the same second as the
    # sign-in counts as before it.
    [ "$since" -gt "$signed_in_at" ] || why="the owner signed in to Obsidian since it started"
  fi
  if [ -z "$why" ]; then
    echo "==> $dir: running, unchanged"
    continue
  fi
  echo "==> $dir: (re)starting its sync – $why"
  systemctl --user restart "$unit"
  printf '%s\n' "$OBSIDIAN_HEADLESS_VERSION" >"$stamp"
  started=1
done

note_stray_units

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
  # Its latest start only: an earlier start's cause may no longer hold.
  log=$(journalctl --user -u "$unit" -I -n 30 --no-pager -o cat 2>/dev/null || true)
  echo "!! $dir: not active" >&2
  # The latest line that names a cause. ob reports the subscription and a
  # deleted vault through its sign-in error, "Failed to authenticate: <reason>",
  # so those are matched first.
  cause=$(grep -E 'subscription to Obsidian Sync has expired|no longer exists|Vault not found|Encryption key not found|Another sync instance|No account logged in|Failed to authenticate' <<<"$log" | tail -1 || true)
  case $cause in
    *"subscription to Obsidian Sync has expired"*)
      echo "   Owner's step: the Obsidian Sync subscription has expired. Renew it in Obsidian's account settings, then run this again." >&2
      ;;
    *"no longer exists"* | *"Vault not found"*)
      echo "   The remote vault ${VAULT_NAMES[$i]} was deleted or renamed in Obsidian Sync. Fix its entry in VAULTS, then run this again." >&2
      ;;
    *"Encryption key not found"*)
      echo "   The vault's stored encryption key is missing. Unlink it, then run this again and the owner types the encryption password:" >&2
      echo "     ob sync-unlink --path $WORKSPACE/$dir" >&2
      ;;
    *"Another sync instance"*)
      echo "   Another ob sync is running for this vault. Find it with: pgrep -af 'ob sync'" >&2
      ;;
    *"No account logged in"* | *"Failed to authenticate"*)
      echo "   Obsidian is signed out, or refused the stored sign-in. $refused_step" >&2
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
echo "Watch a sync: journalctl --user -u obsidian-sync@<dir>.service -f"
