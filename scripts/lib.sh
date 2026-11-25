# shellcheck shell=bash
# Sourced by every script in scripts/ and optional/. read_inputs loads box.env
# from the repo root, where an environment variable of the same name wins over
# the file, even an empty one, and refuses any value a later step would trip
# over.
#
# The system paths below can be pointed elsewhere from the environment so
# tests/run.sh can run the scripts against a temporary directory. Nothing on a
# box sets them.

CLOUD_BOX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

INPUT_NAMES="BOX_USER OPERATOR_PUBKEY REPOS RC_REPOS RC_SPAWN RC_CAPACITY"

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

# Sets REPO_DIRS and REPO_SLUGS from REPOS, and RC_DIRS and RC_AGENTS from
# RC_REPOS, as parallel arrays.
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

  local entries entry dir slug agent
  REPO_DIRS=()
  REPO_SLUGS=()
  read -r -a entries <<<"${REPOS:-}"
  for entry in ${entries[@]+"${entries[@]}"}; do
    dir=${entry%%=*}
    slug=${entry#*=}
    [ "$dir" != "$entry" ] || die "REPOS entry '$entry' is not <local dir>=<github owner/repo>"
    case $dir in
      '') die "REPOS entry '$entry': the local directory is empty" ;;
      .) die "REPOS entry '$entry': the local directory is '.', which would be ~/Workspace itself" ;;
      /*) die "REPOS entry '$entry': the local directory is an absolute path" ;;
      */*) die "REPOS entry '$entry': the local directory contains '/'" ;;
      *..*) die "REPOS entry '$entry': the local directory contains '..'" ;;
    esac
    [[ $dir =~ ^[A-Za-z0-9._-]+$ ]] || die "REPOS entry '$entry': use only letters, digits, '.', '_' and '-' in the local directory"
    if in_list "$dir" ${REPO_DIRS[@]+"${REPO_DIRS[@]}"}; then
      die "REPOS entry '$entry': the local directory '$dir' is repeated"
    fi
    [[ $slug =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "REPOS entry '$entry': '$slug' is not <github owner>/<repo>"
    REPO_DIRS+=("$dir")
    REPO_SLUGS+=("$slug")
  done
  [ ${#REPO_DIRS[@]} -gt 0 ] || die "REPOS is missing: $where"

  RC_DIRS=()
  RC_AGENTS=()
  if [ -n "${RC_REPOS:-}" ]; then
    read -r -a entries <<<"$RC_REPOS"
  else
    entries=("${REPO_DIRS[@]}")
  fi
  for entry in "${entries[@]}"; do
    dir=${entry%%:*}
    agent=
    [ "$dir" = "$entry" ] || agent=${entry#*:}
    in_list "$dir" "${REPO_DIRS[@]}" || die "RC_REPOS entry '$entry': '$dir' is not a local directory in REPOS"
    if in_list "$dir" ${RC_DIRS[@]+"${RC_DIRS[@]}"}; then
      die "RC_REPOS entry '$entry': '$dir' is repeated"
    fi
    [ "$dir" = "$entry" ] || [[ $agent =~ ^[A-Za-z0-9._-]+$ ]] || die "RC_REPOS entry '$entry': '$agent' is not an agent name"
    RC_DIRS+=("$dir")
    RC_AGENTS+=("$agent")
  done

  RC_SPAWN=${RC_SPAWN:-same-dir}
  case $RC_SPAWN in
    same-dir | worktree) ;;
    *) die "RC_SPAWN=$RC_SPAWN: use same-dir or worktree" ;;
  esac
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
  local found
  found=$(find "$CLOUD_BOX_DIR" ! -type l \( ! -uid "$EUID" -o -perm /022 \) -print -quit)
  [ -z "$found" ] || die "$found can be changed by an account other than root. Fix the checkout with: chown -R root:root $CLOUD_BOX_DIR && chmod -R go-w $CLOUD_BOX_DIR"
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

# Marks (hit) an active authorized_keys line holding key k, judged by the field
# after the key type, so neither a comment nor a commented-out line counts.
# shellcheck disable=SC2016
KEY_LINE='{ hit = 0 } !/^[[:space:]]*#/ { for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/ && $(i + 1) == k) hit = 1 }'

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
  if [ ! -f "$file" ]; then
    echo "    $file does not exist"
    return 0
  fi
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

grant_operator_key() {
  local file
  file=$(user_authorized_keys)
  if [ -e "$HANDED_OVER_MARKER" ]; then
    echo "    $HANDED_OVER_MARKER exists: this box has been handed over, so the operator's key is not added again"
    return
  fi
  as_box_user_lib add_key "$file" "$OPERATOR_PUBKEY"
}

revoke_operator_key() {
  local file blob
  file=$(user_authorized_keys)
  blob=$(key_blob "$OPERATOR_PUBKEY")
  remove_key "$ROOT_AUTHORIZED_KEYS" "$OPERATOR_PUBKEY" || die "the operator's key may still be in $ROOT_AUTHORIZED_KEYS"
  as_box_user_lib remove_key "$file" "$OPERATOR_PUBKEY" || die "the operator's key may still be in $file"
  if file_has_key "$ROOT_AUTHORIZED_KEYS" "$blob" || as_box_user_lib file_has_key "$file" "$blob"; then
    die "the operator's key is still in an authorized_keys file, so the handover is not complete"
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
