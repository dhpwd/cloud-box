# shellcheck shell=bash
# Sourced by every script in scripts/ and optional/. read_inputs loads box.env
# from the repo root, where an environment variable of the same name wins over
# the file, even an empty one, and refuses any value a later step would trip
# over.
#
# The system paths below can be pointed elsewhere from the environment so
# tests/run.sh can run the scripts against a temporary directory. Nothing on a
# box sets them.

# Resolved, so the checks on it see where the checkout really lives, and the
# path the script was started through, which require_root holds to it.
CLOUD_BOX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CLOUD_BOX_STARTED=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -L)
CLOUD_BOX_LIB="$CLOUD_BOX_DIR/scripts/lib.sh"
BOX_ENV_FILE=${BOX_ENV_FILE:-$CLOUD_BOX_DIR/box.env}
CLOUD_BOX_STATE_DIR=${CLOUD_BOX_STATE_DIR:-/etc/cloud-box}
CLOUD_BOX_RUN_DIR=${CLOUD_BOX_RUN_DIR:-/run/cloud-box}
SSHD_CONFIG=${SSHD_CONFIG:-/etc/ssh/sshd_config}
SSHD_CONFIG_D=${SSHD_CONFIG_D:-/etc/ssh/sshd_config.d}
ROOT_AUTHORIZED_KEYS=${ROOT_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}

HANDED_OVER_MARKER="$CLOUD_BOX_STATE_DIR/handed-over"
# shellcheck disable=SC2034 # read by the scripts that source this
CLOSED_MARKER="$CLOUD_BOX_STATE_DIR/closed"
CLOSE_LOCK="$CLOUD_BOX_RUN_DIR/close.lock"
KEYS_LOCK="$CLOUD_BOX_RUN_DIR/keys.lock"
GRANTS_FILE="$CLOUD_BOX_STATE_DIR/operator-grant"

INPUT_NAMES="BOX_USER OPERATOR_PUBKEY REPOS VAULTS RC_REPOS RC_SPAWN RC_CAPACITY"

die() {
  printf '!! %s\n' "$*" >&2
  exit 1
}

# Parsed rather than sourced: root reads this file, and parsing runs nothing
# that is written in it.
load_box_env() {
  local line key val
  [ -f "$BOX_ENV_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    case $line in '' | '#'*) continue ;; esac
    line=${line#export }
    key=${line%%=*}
    [ "$key" != "$line" ] || die "$BOX_ENV_FILE: expected NAME=value, found: $line"
    case " $INPUT_NAMES " in
      *" $key "*) ;;
      *) die "$BOX_ENV_FILE: unknown input $key (known: $INPUT_NAMES)" ;;
    esac
    val=${line#*=}
    case $val in
      \"*\") val=${val#\"} && val=${val%\"} ;;
      \'*\') val=${val#\'} && val=${val%\'} ;;
    esac
    [ -n "${!key+set}" ] || printf -v "$key" '%s' "$val"
  done <"$BOX_ENV_FILE"
}

# Refuses a local directory under ~/Workspace that isn't one plain name, or
# that an earlier entry of the same input already uses.
check_local_dir() {
  local input=$1 entry=$2 dir=$3
  shift 3
  case $dir in
    '') die "$input entry '$entry': the local directory is empty" ;;
    .) die "$input entry '$entry': the local directory is '.', which would be ~/Workspace itself" ;;
    /*) die "$input entry '$entry': the local directory is an absolute path" ;;
    */*) die "$input entry '$entry': the local directory contains '/'" ;;
    *..*) die "$input entry '$entry': the local directory contains '..'" ;;
  esac
  [[ $dir =~ ^[A-Za-z0-9._-]+$ ]] || die "$input entry '$entry': use only letters, digits, '.', '_' and '-' in the local directory"
  if in_list "$dir" "$@"; then
    die "$input entry '$entry': the local directory '$dir' is repeated"
  fi
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Sets REPO_DIRS and REPO_SLUGS from REPOS, VAULT_DIRS and VAULT_REMOTES from
# VAULTS, and RC_DIRS and RC_AGENTS from RC_REPOS, as parallel arrays.
# WORKSPACE_DIRS is every folder in ~/Workspace they name: the repos, then the
# vaults that aren't also repos.
read_inputs() {
  load_box_env
  local where="set it in $BOX_ENV_FILE (box.env.example shows the format)"

  [ -n "${BOX_USER:-}" ] || die "BOX_USER is missing: $where"
  [ "$BOX_USER" != root ] || die "BOX_USER=root: the agents must run as an account without admin rights"
  [[ $BOX_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "BOX_USER=$BOX_USER is not a valid user name"

  [ -n "${OPERATOR_PUBKEY:-}" ] || die "OPERATOR_PUBKEY is missing: $where"
  case $OPERATOR_PUBKEY in *$'\n'*) die "OPERATOR_PUBKEY must be one public key on one line" ;; esac
  printf '%s\n' "$OPERATOR_PUBKEY" | ssh-keygen -l -f - >/dev/null 2>&1 ||
    die "OPERATOR_PUBKEY is not a valid SSH public key (is the example's placeholder still in place?)"

  local entries entry dir slug remote agent
  REPO_DIRS=()
  REPO_SLUGS=()
  read -r -a entries <<<"${REPOS:-}"
  for entry in ${entries[@]+"${entries[@]}"}; do
    dir=${entry%%=*}
    slug=${entry#*=}
    [ "$dir" != "$entry" ] || die "REPOS entry '$entry' is not <local dir>=<github owner/repo>"
    check_local_dir REPOS "$entry" "$dir" ${REPO_DIRS[@]+"${REPO_DIRS[@]}"}
    [[ $slug =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "REPOS entry '$entry': '$slug' is not <github owner>/<repo>"
    REPO_DIRS+=("$dir")
    REPO_SLUGS+=("$slug")
  done

  # Separated by ';', because a remote vault's name can hold spaces.
  case ${VAULTS:-} in *$'\n'*) die "VAULTS must be on one line, its entries separated by ';'" ;; esac
  VAULT_DIRS=()
  VAULT_REMOTES=()
  IFS=';' read -r -a entries <<<"${VAULTS:-}"
  for entry in ${entries[@]+"${entries[@]}"}; do
    entry=$(trim "$entry")
    [ -n "$entry" ] || continue
    [[ $entry == *=* ]] || die "VAULTS entry '$entry' is not <local dir>=<remote vault name or ID>"
    dir=$(trim "${entry%%=*}")
    remote=$(trim "${entry#*=}")
    check_local_dir VAULTS "$entry" "$dir" ${VAULT_DIRS[@]+"${VAULT_DIRS[@]}"}
    [ -n "$remote" ] || die "VAULTS entry '$entry': the remote vault is empty"
    if in_list "$remote" ${VAULT_REMOTES[@]+"${VAULT_REMOTES[@]}"}; then
      die "VAULTS entry '$entry': the remote vault '$remote' is named twice"
    fi
    VAULT_DIRS+=("$dir")
    VAULT_REMOTES+=("$remote")
  done
  [ ${#REPO_DIRS[@]} -gt 0 ] || [ ${#VAULT_DIRS[@]} -gt 0 ] || die "REPOS and VAULTS are both empty: $where"
  WORKSPACE_DIRS=(${REPO_DIRS[@]+"${REPO_DIRS[@]}"})
  for dir in ${VAULT_DIRS[@]+"${VAULT_DIRS[@]}"}; do
    in_list "$dir" "${WORKSPACE_DIRS[@]}" || WORKSPACE_DIRS+=("$dir")
  done

  RC_SPAWN=${RC_SPAWN:-same-dir}
  case $RC_SPAWN in
    same-dir | worktree) ;;
    *) die "RC_SPAWN=$RC_SPAWN: use same-dir or worktree" ;;
  esac

  RC_DIRS=()
  RC_AGENTS=()
  if [ -n "${RC_REPOS:-}" ]; then
    read -r -a entries <<<"$RC_REPOS"
  else
    entries=("${WORKSPACE_DIRS[@]}")
  fi
  for entry in "${entries[@]}"; do
    dir=${entry%%:*}
    agent=
    [ "$dir" = "$entry" ] || agent=${entry#*:}
    in_list "$dir" "${WORKSPACE_DIRS[@]}" || die "RC_REPOS entry '$entry': '$dir' is not a local directory in REPOS or VAULTS"
    if in_list "$dir" ${RC_DIRS[@]+"${RC_DIRS[@]}"}; then
      die "RC_REPOS entry '$entry': '$dir' is repeated"
    fi
    [ "$dir" = "$entry" ] || [[ $agent =~ ^[A-Za-z0-9._-]+$ ]] || die "RC_REPOS entry '$entry': '$agent' is not an agent name"
    [ "$RC_SPAWN" != worktree ] || in_list "$dir" ${REPO_DIRS[@]+"${REPO_DIRS[@]}"} ||
      die "RC_SPAWN=worktree: the Remote Control entry '$entry' is a vault with no git repository, and worktree mode needs a git repository. Use RC_SPAWN=same-dir, or leave $dir out of RC_REPOS"
    RC_DIRS+=("$dir")
    RC_AGENTS+=("$agent")
  done
  RC_CAPACITY=${RC_CAPACITY:-}
  [ -z "$RC_CAPACITY" ] || [[ $RC_CAPACITY =~ ^[1-9][0-9]*$ ]] || die "RC_CAPACITY=$RC_CAPACITY: use a whole number from 1, or leave it unset"
}

# The lockdown's close and the handover both take this lock without waiting,
# on fd 9. The revert job that close arms inherits fd 9, so the lock stays held
# for exactly as long as a revert is pending, and a reboot or a killed job
# releases it.
take_close_lock() {
  mkdir -p "$CLOUD_BOX_RUN_DIR"
  exec 9>"$CLOSE_LOCK"
  flock -n 9 || die "$1"
}

# Every process the close started, at any depth, except this job and what
# it runs.
close_tree() {
  local c
  for c in $(pgrep -P "$1"); do
    [ "$c" = "$$" ] && continue
    echo "$c"
    close_tree "$c"
  done
}

# The close's dead-man switch, started in the background by
# 02-tailscale-lockdown.sh close, in a session of its own. Unless the close
# confirms first, it stops the close and everything the close started, then
# undoes the close, so it is always the last to change anything. It holds the
# close lock (fd 9) until it returns. Its first sleep doesn't, so killing it
# frees the lock at once.
# A write to the close's terminal can block (a paused terminal, or a pipe
# nobody reads), so it is made by a child that is killed after two seconds.
# shellcheck disable=SC2016 # the child's $1 is the message
tell_close() { timeout 2 bash -c 'printf "%s\n" "$1" >&3' _ "$1" 2>/dev/null || true; }

revert_close() {
  local after=$1 decided=$2 dropin=$3 marker=$4 close=$5 ppid pids p msg failed='' stopped=''
  sleep "$after" 9>&-
  mkdir "$decided" 2>/dev/null || return 0
  exec 3>/dev/null
  # This job's parent is the close for as long as the close runs, so a process
  # that has since taken the close's PID is never signalled.
  read -r _ _ _ ppid _ <"/proc/$$/stat"
  if [ "$ppid" = "$close" ]; then
    # The close's stderr, kept for the report once the close is gone. A pipe is
    # opened read-write, so the open can't wait for a reader.
    if [ -p "/proc/$close/fd/2" ]; then exec 3<>"/proc/$close/fd/2"; else exec 3>>"/proc/$close/fd/2"; fi || exec 3>/dev/null
    # Stopped first, so nothing in the tree can start another process before
    # the kill.
    kill -STOP "$close" 2>/dev/null
    pids=$(close_tree "$close")
    for p in $pids; do kill -STOP "$p" 2>/dev/null; done
    pids="$pids $(close_tree "$close")"
    for p in $pids "$close"; do kill -KILL "$p" 2>/dev/null; done
    for _ in $(seq 50); do
      read -r _ _ _ ppid _ <"/proc/$$/stat"
      [ "$ppid" = "$close" ] || break
      sleep 0.1
    done
    stopped=1
  fi
  rm -f "$dropin" "$marker" || failed="removing $dropin"
  systemctl restart ssh || failed="${failed:+$failed, }restarting sshd"
  ufw --force disable >/dev/null || failed="${failed:+$failed, }turning ufw off"
  if [ -z "$failed" ]; then
    msg="The revert has run. Public SSH is open again. Run 'close' again."
  else
    msg="The revert did not finish ($failed). Check sshd and ufw from the provider's console."
  fi
  # Reported only once the undo is done. The journal keeps the result after an
  # explicit no, when there is no close left to tell.
  timeout 5 logger -t cloud-box "$msg" 2>/dev/null || true
  [ -z "$stopped" ] || tell_close "!! ${after}s ran out, so the close was stopped and undone"
  tell_close "!! $msg"
}

# The owner's laptop takes push.sh from GitHub at the commit this checkout is
# at, never through a session on the box: the box user's login files decide
# what a session as that user serves. Printed by root steps, which the agents
# can't influence. The single-quoted line is printed as it is, for the laptop's
# shell to run.
# shellcheck disable=SC2016
print_push_line() {
  local commit origin repo blob box_repo=
  commit=$(git -C "$CLOUD_BOX_DIR" rev-parse HEAD)
  origin=$(git -C "$CLOUD_BOX_DIR" remote get-url origin 2>/dev/null || true)
  repo=${origin#https://github.com/}
  repo=${repo#git@github.com:}
  repo=${repo%.git}
  if ! [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "    !! this checkout's origin isn't a github.com URL this can read, so there is no URL for the laptop. Push this commit to GitHub first"
    return 0
  fi
  # The file's bytes against the committed blob, which a flag such as
  # assume-unchanged can't hide.
  blob=$(git -C "$CLOUD_BOX_DIR" rev-parse "$commit:laptop/push.sh" 2>/dev/null || true)
  if [ -z "$blob" ] || [ "$(git -C "$CLOUD_BOX_DIR" hash-object --no-filters laptop/push.sh 2>/dev/null)" != "$blob" ]; then
    echo "    !! laptop/push.sh here differs from $commit, so there is no line for the laptop. Commit and push the change, or undo it with: t=\$(mktemp $(printf '%q' "$CLOUD_BOX_DIR/laptop/push.sh.XXXXXX")) && git -C $(printf '%q' "$CLOUD_BOX_DIR") show HEAD:laptop/push.sh >\"\$t\" && chmod 755 \"\$t\" && mv \"\$t\" $(printf '%q' "$CLOUD_BOX_DIR/laptop/push.sh") || rm -f \"\$t\""
    return 0
  fi
  [ "$CLOUD_BOX_DIR" = /opt/cloud-box ] || box_repo="BOX_REPO=$(printf '%q' "$CLOUD_BOX_DIR") "
  echo "    This checkout is at $commit. On the owner's laptop, step 5 of the README runs:"
  printf '      ( d=$(mktemp -d) || exit 1; trap %s EXIT; curl -fsSL -o "$d/push.sh" https://raw.githubusercontent.com/%s/%s/laptop/push.sh && %s/bin/bash "$d/push.sh" %s@<box name> --connectors <name,name> )\n' \
    "'rm -rf \"\$d\"'" "$repo" "$commit" "$box_repo" "$BOX_USER"
}

in_list() {
  local needle=$1 item
  shift
  for item; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

# Root later runs scripts from this checkout, so an account that could change
# it could run its own code as root.
require_root() {
  [ "$(id -u)" -eq 0 ] || die "run this as root"
  # Through a symlink, the path a step is started from and the checkout it
  # reaches have different parents, and either could be swapped. A root step
  # runs only from the resolved path, so one walk covers both.
  [ "$CLOUD_BOX_STARTED" = "$CLOUD_BOX_DIR" ] ||
    die "this was started through $CLOUD_BOX_STARTED, which reaches the checkout through a symlink. Run it from $CLOUD_BOX_DIR"
  local found
  # A symlink's own mode is 777, so this refuses one anywhere in the checkout:
  # what it points to is never checked.
  found=$(find "$CLOUD_BOX_DIR" \( ! -uid "$EUID" -o -perm /022 \) -print -quit)
  [ ! -L "$found" ] || die "$found is a symlink, which a root step won't run through. Make a fresh clone of the repo at $CLOUD_BOX_DIR"
  [ -z "$found" ] || die "$found can be changed by an account other than root. Fix the checkout with: chown -R root:root $CLOUD_BOX_DIR && chmod -R go-w $CLOUD_BOX_DIR"
  # A directory above the checkout that another account can write lets it swap
  # the checkout for its own.
  local d=$CLOUD_BOX_DIR
  while [ "$d" != / ]; do
    d=$(dirname "$d")
    # The tests set this, so they don't depend on where their checkout sits.
    [ "$d" != "${CLOUD_BOX_TRUSTED_DIR:-}" ] || break
    found=$(find "$d" -maxdepth 0 \( ! -uid 0 ! -uid "$EUID" -o -perm /022 \) -print)
    [ -z "$found" ] || die "$d can be changed by an account other than root, so the checkout inside it could be replaced. Put the checkout at /opt/cloud-box"
  done
}

require_box_user() {
  [ "$(id -u)" -ne 0 ] || die "run this as $BOX_USER, not as root"
  [ "$(id -un)" = "$BOX_USER" ] || die "run this as $BOX_USER (BOX_USER in box.env), not as $(id -un)"
}

# Files in the box user's home are edited as that user, never as root: the
# agents run as that account and could point a path there at a system file.
as_box_user() {
  runuser -u "$BOX_USER" -- "$@"
}

# Runs one of this file's functions as the box user, stopping at the first
# command that fails. The script is single-quoted on purpose: its $1.. are the
# arguments after it.
# shellcheck disable=SC2016
as_box_user_lib() {
  as_box_user bash -c 'set -e; . "$1"; shift; "$@"' _ "$CLOUD_BOX_LIB" "$@"
}

user_authorized_keys() {
  if [ -n "${USER_AUTHORIZED_KEYS:-}" ]; then
    printf '%s\n' "$USER_AUTHORIZED_KEYS"
    return
  fi
  local home
  home=$(getent passwd "$BOX_USER" | cut -d: -f6)
  [ -n "$home" ] || die "$BOX_USER has no home directory"
  printf '%s\n' "$home/.ssh/authorized_keys"
}

# The base64 field identifies a key whatever its options or comment.
key_blob() {
  printf '%s\n' "$1" | awk '{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $(i + 1); exit } }'
}

# Marks (hit) an active authorized_keys line whose key is k. A line is
# [options] keytype base64 [comment]: the options field is skipped the way
# OpenSSH skips it (quotes may hold spaces, and a backslash escapes only a
# quote), and nothing after the key counts, so neither a comment nor a
# commented-out line can match.
# shellcheck disable=SC2016
KEY_LINE='
{ hit = 0 }
!/^[[:space:]]*(#|$)/ {
  line = $0
  sub(/^[[:space:]]+/, "", line)
  if (line !~ /^(ssh-|ecdsa-|sk-)/) {
    q = 0
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (c == "\\" && substr(line, i + 1, 1) == "\"") i++
      else if (c == "\"") q = !q
      else if (!q && (c == " " || c == "\t")) break
    }
    line = substr(line, i + 1)
    sub(/^[[:space:]]+/, "", line)
  }
  nf = split(line, f, /[[:space:]]+/)
  hit = nf >= 2 && f[1] ~ /^(ssh-|ecdsa-|sk-)/ && f[2] == k
}'

# absent, present or unreadable. A key file that can't be read is never taken
# for one without the key: it is absent only when looking it up reports no such
# file and it isn't a link. Any other failure anywhere on the path, such as a
# directory that can't be entered, leaves its contents unknown.
key_file_state() {
  local err
  if err=$(LC_ALL=C stat -L -- "$1" 2>&1 >/dev/null); then
    if [ -r "$1" ]; then echo present; else echo unreadable; fi
  elif [ ! -L "$1" ] && [[ $err == *": No such file or directory" ]]; then
    echo absent
  else
    echo unreadable
  fi
}

# Succeeds only when the file provably doesn't exist, or is readable and holds
# no active copy of the key.
key_absent() {
  local rc=0
  case $(key_file_state "$1") in
    absent) return 0 ;;
    present)
      # awk exits 1 when the key isn't there and 2 when it can't read the file.
      file_has_key "$1" "$2" || rc=$?
      [ "$rc" -eq 1 ]
      ;;
    *) return 1 ;;
  esac
}

file_has_key() {
  [ -f "$1" ] && awk -v k="$2" "$KEY_LINE"' hit { found = 1 } END { exit !found }' "$1"
}

add_key() {
  local file=$1 pubkey=$2 blob
  blob=$(key_blob "$pubkey")
  mkdir -p "$(dirname "$file")"
  chmod 700 "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file"
  if file_has_key "$file" "$blob"; then
    echo "    the operator's key is already in $file"
    return
  fi
  if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then echo >>"$file"; fi
  printf '%s\n' "$pubkey" >>"$file"
  echo "    added the operator's key to $file"
}

# Writes the kept lines to a new file beside the old one and renames it over,
# so a failed write leaves the original as it was.
remove_key() {
  local file=$1 blob tmp n
  blob=$(key_blob "$2")
  case $(key_file_state "$file") in
    absent)
      echo "    $file does not exist"
      return 0
      ;;
    unreadable)
      echo "!! cannot read $file" >&2
      return 1
      ;;
  esac
  n=$(awk -v k="$blob" "$KEY_LINE"' hit { n++ } END { print n + 0 }' "$file")
  if ! tmp=$(mktemp "$file.XXXXXX") ||
    ! awk -v k="$blob" "$KEY_LINE"' !hit { print }' "$file" >"$tmp" ||
    ! mv -f "$tmp" "$file"; then
    rm -f "${tmp:-}"
    echo "!! could not rewrite $file" >&2
    return 1
  fi
  echo "    removed $n line(s) from $file"
}

# ssh-keygen prints each key's comment beside its fingerprint, and comments
# name people, so only the fingerprint field is printed.
key_fingerprints() {
  local out
  if [ ! -s "$1" ] || ! out=$(ssh-keygen -l -f "$1" 2>/dev/null); then
    echo "      (no keys)"
    return
  fi
  printf '%s\n' "$out" | awk '{ print "      " $2 }'
}

# Held while the base checks the marker and adds the key, and while the
# handover marks the box and removes the key, so no grant lands after a
# handover.
take_keys_lock() {
  mkdir -p "$CLOUD_BOX_RUN_DIR"
  exec 8>"$KEYS_LOCK"
  flock -w 60 8 || die "another 01-base.sh or 06-handover.sh is changing the operator's key. Let it finish, then run this again"
}

# The handover removes the key the base granted, so the grant is recorded
# where only root can change it.
grant_operator_key() {
  local file line
  file=$(user_authorized_keys)
  take_keys_lock
  if [ -e "$HANDED_OVER_MARKER" ]; then
    echo "    $HANDED_OVER_MARKER exists: this box has been handed over, so the operator's key is not added again"
    exec 8>&-
    return
  fi
  line="$BOX_USER $(key_blob "$OPERATOR_PUBKEY")"
  mkdir -p "$CLOUD_BOX_STATE_DIR"
  grep -qxF "$line" "$GRANTS_FILE" 2>/dev/null || printf '%s\n' "$line" >>"$GRANTS_FILE"
  local rc=0
  as_box_user_lib add_key "$file" "$OPERATOR_PUBKEY" || rc=$?
  exec 8>&-
  return "$rc"
}

# Refuses a handover whose inputs name another account or key than the ones
# the base granted, which it would otherwise report removed while the granted
# key stays.
require_recorded_grant() {
  local line want found=
  want="$BOX_USER $(key_blob "$OPERATOR_PUBKEY")"
  if [ -e "$GRANTS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      [ "$line" = "$want" ] ||
        die "01-base.sh granted ${line%% *} a key that this run's BOX_USER and OPERATOR_PUBKEY don't name. Run this with the inputs 01-base.sh ran with, or remove that key by hand and its line from $GRANTS_FILE"
      found=1
    done <"$GRANTS_FILE"
  fi
  [ -n "$found" ] ||
    die "$GRANTS_FILE holds no record of the key 01-base.sh granted, so which key to remove can't be checked. Run 01-base.sh with the inputs it first ran with, which records it, then run this"
}

revoke_operator_key() {
  local file blob
  file=$(user_authorized_keys)
  blob=$(key_blob "$OPERATOR_PUBKEY")
  remove_key "$ROOT_AUTHORIZED_KEYS" "$OPERATOR_PUBKEY" || die "the operator's key may still be in $ROOT_AUTHORIZED_KEYS"
  as_box_user_lib remove_key "$file" "$OPERATOR_PUBKEY" || die "the operator's key may still be in $file"
  if ! key_absent "$ROOT_AUTHORIZED_KEYS" "$blob" || ! as_box_user_lib key_absent "$file" "$blob"; then
    die "the operator's key is still in an authorized_keys file, or one can't be read, so the handover is not complete"
  fi
  echo "    keys left for root:"
  key_fingerprints "$ROOT_AUTHORIZED_KEYS"
  echo "    keys left for $BOX_USER:"
  as_box_user_lib key_fingerprints "$file"
}

# sshd uses the first value it reads for each keyword. Debian's sshd_config
# includes the drop-ins, in name order, on its first lines.
sshd_first_setter() {
  local LC_ALL=C f
  for f in "$SSHD_CONFIG_D"/*.conf "$SSHD_CONFIG"; do
    [ -f "$f" ] || continue
    if grep -qiE "^[[:space:]]*$1([[:space:]]|=)" "$f"; then
      printf '%s\n' "$f"
      return
    fi
  done
  echo "no file (the built-in default applies)"
}

sshd_setting() {
  sshd -T -C "user=$1" | awk -v k="$2" '$1 == k { print $2; exit }'
}

print_sshd_settings() {
  local user
  for user; do
    echo "    as $user:"
    sshd -T -C "user=$user" | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) ' | sed 's/^/      /'
  done
}

# Exits naming the file responsible if a password or keyboard-interactive
# sign-in is still allowed for any of the users given.
require_sshd_key_only() {
  local user kw
  for user; do
    for kw in passwordauthentication kbdinteractiveauthentication; do
      [ "$(sshd_setting "$user" "$kw")" = no ] ||
        die "sshd still allows $kw for $user. The first file that sets it is $(sshd_first_setter "$kw"). If that file says no, a Match block overrides it"
    done
  done
}
