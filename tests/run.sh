#!/usr/bin/env bash
# Tests for the scripts' checks, the laptop script's selection and the key and
# lockdown handling. Needs no root and no network, and is safe on a live box:
# every script runs under env -i with HOME and TMPDIR in a temporary directory,
# no session sockets, and a stub directory first on PATH that holds every
# command a script under test could use to change a host. The temporary
# directory is removed at the end.
#
#   tests/run.sh

# Stub bodies and bash -c scripts are single-quoted on purpose: they expand
# when they run, not here.
# shellcheck disable=SC2016
set -euo pipefail
trap 'echo "tests/run.sh stopped at line $LINENO" >&2' ERR

REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
STUBS="$T/stubs"
LOG="$T/calls.log"
mkdir -p "$STUBS" "$T/tmp" "$T/keys" "$T/sshd/d"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "ok   $1"
}
bad() {
  fail=$((fail + 1))
  echo "FAIL $1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     | /'
}

# ---- stubs -------------------------------------------------------------------

stub() {
  printf '#!/bin/bash\necho "%s $*" >>"$STUB_LOG"\n%s\n' "$1" "${2:-exit 0}" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

for c in apt apt-get bun pnpm npm pre-commit journalctl scp; do stub "$c"; done
stub ufw 'case "$1 $2" in "--force reset") [ -z "${STUB_UFW_SLOW:-}" ] || sleep 3 ;; esac'
for c in curl sudo dpkg adduser useradd usermod gpasswd passwd locale-gen update-locale getent; do
  stub "$c" 'echo "stub: $0 must not run in tests" >&2; exit 1'
done
stub uv 'case $1 in tool) exit 0 ;; esac'
stub nft 'echo "table inet filter { chain input { policy drop; } }"'
stub iptables 'echo "-P INPUT DROP"'
stub ip6tables 'echo "-P INPUT DROP"'
stub id 'case $1 in -u) echo "${STUB_UID:-1000}" ;; -un) echo "${STUB_USER:-agent}" ;; *) exec /usr/bin/id "$@" ;; esac'
stub runuser 'while [ "$1" != -- ]; do shift; done; shift; exec "$@"'
stub loginctl 'echo "${STUB_LINGER:-yes}"'
stub systemctl 'case $* in *is-active*) [ "${STUB_ACTIVE:-no}" = yes ] ;; *show*) echo 4242 ;; esac'
stub ps 'case " $* " in *" -ww "*) printf "%s\n" "${STUB_PS_ARGS:-}" ;; *) printf "%s\n" "${STUB_PS_ARGS:0:40}" ;; esac'
# Real git for everything but pull, which would reach a network or, from an
# empty .git, a repository above the temporary directory.
stub git 'for a; do [ "$a" != pull ] || exit "${STUB_GIT_PULL:-0}"; done; exec /usr/bin/git "$@"'
stub tailscale 'case $1 in ip) echo 100.64.0.1 ;; status) echo "{\"Self\":{\"DNSName\":\"box.example.ts.net.\"}}" ;; esac'
stub sshd 'case $1 in -T) printf "passwordauthentication %s\nkbdinteractiveauthentication no\npermitrootlogin %s\nlistenaddress 100.64.0.1:22\nallowusers agent\n" "${STUB_SSHD_PASSWORD:-no}" "${STUB_SSHD_ROOT:-no}" ;; esac'
stub gh 'case "$1 $2" in
  "auth status") [ "${STUB_GH_AUTH:-in}" = in ] ;;
  "repo clone") mkdir -p "$4/.git" && touch "$4/package-lock.json" "$4/uv.lock" ;;
esac'
# Records each call: its arguments in <n>.args and its standard input in <n>.in.
stub ssh 'd="$STUB_DIR/ssh"; mkdir -p "$d"; n=$(ls "$d" | wc -l); printf "%s\n" "$*" >"$d/$n.args"; cat >"$d/$n.in"
case $* in *"${STUB_SSH_FAIL:-no call matches this}"*) exit 1 ;; esac'
# Keeps registrations as files, one per server, and lists them the way the real
# `claude mcp list` does: with each server's URL or full command line.
stub claude 'reg="$STUB_DIR/claude-registry"; mkdir -p "$reg"
case "$1 $2" in
  "auth status")
    if [ "${STUB_CLAUDE_AUTH:-in}" = in ]; then echo "{\"loggedIn\": true}"; else echo "{\"loggedIn\": false}"; exit 1; fi ;;
  "mcp get") [ -f "$reg/$3" ] ;;
  "mcp add-json") [ ! -f "$reg/$5" ] || exit 1; cat >"$reg/$5" ;;
  "mcp remove") rm -f "$reg/$5" ;;
  "mcp list")
    echo "Checking MCP server health..."
    for f in "$reg"/*; do
      [ -f "$f" ] || continue
      echo "$(basename "$f"): $(jq -r "if .url then .url else ([.command] + (.args // []) + ((.env // {}) | [.[]])) | join(\" \") end" "$f") - ✔ Connected"
    done
    echo "claude.ai Example: https://claude.ai/mcp?token=CLAUDEAIKEY444 - ! Needs authentication"
    echo "claude.ai Broken: https://claude.ai/b - ✘ Failed to connect: https://claude.ai/b?token=DIAGKEY666" ;;
esac'

# ---- fixtures ----------------------------------------------------------------

ssh-keygen -q -t ed25519 -N '' -C operator@test -f "$T/keys/operator"
ssh-keygen -q -t ed25519 -N '' -C someone-else -f "$T/keys/other"
OPKEY=$(cat "$T/keys/operator.pub")
OTHERKEY=$(cat "$T/keys/other.pub")
OTHER_FP=$(ssh-keygen -l -f "$T/keys/other.pub" | awk '{ print $2 }')
OP_FP=$(ssh-keygen -l -f "$T/keys/operator.pub" | awk '{ print $2 }')
OP_BLOB=$(awk '{ print $2 }' <<<"$OPKEY")
OTHER_BLOB=$(awk '{ print $2 }' <<<"$OTHERKEY")

# Runs a script with nothing from this shell's environment but what is listed,
# plus any NAME=value arguments given before the script.
run() {
  env -i HOME="$T/home" TMPDIR="$T/tmp" LANG=C.UTF-8 PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    STUB_LOG="$LOG" STUB_DIR="$T" BOX_ENV_FILE="$T/no-box.env" \
    CLOUD_BOX_STATE_DIR="$T/state" CLOUD_BOX_RUN_DIR="$T/run" \
    SSHD_CONFIG="$T/sshd/sshd_config" SSHD_CONFIG_D="$T/sshd/d" \
    ROOT_AUTHORIZED_KEYS="$T/keys/root_ak" USER_AUTHORIZED_KEYS="$T/keys/user_ak" \
    BOX_USER=agent OPERATOR_PUBKEY="$OPKEY" REPOS="app=example-org/app api=example-org/api-server" \
    "$@"
}

fresh_home() {
  rm -rf "${T:?}/home" "$T/ssh" "$T/claude-registry"
  mkdir -p "$T/home"
  : >"$LOG"
}

# Paths outside the temporary directory that a script under test would write if
# its isolation failed.
REAL_HOME=$HOME
watched() {
  for p in "$REAL_HOME/.config/systemd/user/claude-rc@.service" /etc/cloud-box /run/cloud-box \
    /etc/ssh/sshd_config.d/00-cloud-box-key-only.conf; do
    if [ -e "$p" ]; then printf '%s %s\n' "$p" "$(sha256sum "$p" 2>/dev/null | cut -c1-16 || echo dir)"; else echo "$p absent"; fi
  done
}
BEFORE=$(watched)

# ---- inputs ------------------------------------------------------------------

expect_refusal() { # name, expected text, then NAME=value overrides and the script
  local name=$1 want=$2 out
  shift 2
  fresh_home
  if out=$(run "$@" 2>&1); then
    bad "$name: exited 0" "$out"
  elif [[ $out != *"$want"* ]]; then
    bad "$name: no '$want' in the output" "$out"
  else
    ok "$name"
  fi
}

for s in scripts/01-base.sh scripts/02-tailscale-lockdown.sh scripts/03-repos.sh scripts/04-connectors.sh \
  scripts/05-remote-control.sh scripts/06-handover.sh optional/terminal.sh optional/playwright-mcp.sh; do
  expect_refusal "missing BOX_USER stops $s" "BOX_USER is missing" BOX_USER= bash "$REPO/$s"
done
expect_refusal "missing OPERATOR_PUBKEY is named" "OPERATOR_PUBKEY is missing" OPERATOR_PUBKEY= bash "$REPO/scripts/03-repos.sh"
expect_refusal "missing REPOS is named" "REPOS is missing" REPOS= bash "$REPO/scripts/03-repos.sh"
expect_refusal "the example's placeholder key is refused" "OPERATOR_PUBKEY is not a valid SSH public key" \
  OPERATOR_PUBKEY="ssh-ed25519 <the builder's public key> <comment>" bash "$REPO/scripts/01-base.sh"
expect_refusal "BOX_USER=root is refused" "BOX_USER=root" BOX_USER=root bash "$REPO/scripts/01-base.sh"
expect_refusal "an empty local directory is refused" "the local directory is empty" REPOS="=org/app" bash "$REPO/scripts/03-repos.sh"
expect_refusal "a '.' local directory is refused" "the local directory is '.'" REPOS=".=org/app" bash "$REPO/scripts/03-repos.sh"
expect_refusal "a repeated local directory is refused" "the local directory 'app' is repeated" REPOS="app=org/app app=org/other" bash "$REPO/scripts/03-repos.sh"
expect_refusal "an absolute local directory is refused" "is an absolute path" REPOS="/srv/app=org/app" bash "$REPO/scripts/03-repos.sh"
expect_refusal "a local directory with '/' is refused" "contains '/'" REPOS="a/b=org/app" bash "$REPO/scripts/03-repos.sh"
expect_refusal "a local directory with '..' is refused" "contains '..'" REPOS="..=org/app" bash "$REPO/scripts/03-repos.sh"
expect_refusal "an RC_REPOS entry missing from REPOS is refused" "'web' is not a local directory in REPOS" \
  RC_REPOS="app web" bash "$REPO/scripts/05-remote-control.sh"

fresh_home
printf 'BOX_USER=from-file\nREPOS="app=org/app"\n' >"$T/box.env"
out=$(run BOX_ENV_FILE="$T/box.env" bash -c 'unset BOX_USER REPOS; . "$1" && read_inputs && echo "$BOX_USER ${REPO_DIRS[*]}"' _ "$REPO/scripts/lib.sh" 2>&1 || true)
if [ "$out" = "from-file app" ]; then ok "box.env is read"; else bad "box.env is read" "$out"; fi
out=$(run BOX_ENV_FILE="$T/box.env" bash -c '. "$1" && read_inputs && echo "$BOX_USER"' _ "$REPO/scripts/lib.sh" 2>&1 || true)
if [ "$out" = agent ]; then
  ok "an environment variable wins over box.env"
else
  bad "an environment variable wins over box.env" "$out"
fi
printf 'RC_CAPACITY=3\n' >"$T/box.env"
out=$(run BOX_ENV_FILE="$T/box.env" RC_CAPACITY= bash -c '. "$1" && read_inputs && echo "[$RC_CAPACITY]"' _ "$REPO/scripts/lib.sh" 2>&1 || true)
if [ "$out" = "[]" ]; then
  ok "an empty environment variable wins over box.env"
else
  bad "an empty environment variable wins over box.env" "$out"
fi

# ---- the stops at an owner's sign-in -----------------------------------------

fresh_home
if out=$(run STUB_GH_AUTH=out bash "$REPO/scripts/03-repos.sh" 2>&1); then
  bad "03-repos.sh stops when GitHub is signed out: exited 0" "$out"
elif [[ $out != *"gh auth login --hostname github.com --git-protocol https --web"* ]]; then
  bad "03-repos.sh stops when GitHub is signed out: owner's step not named" "$out"
elif [ -e "$T/home/Workspace" ] || grep -q 'gh auth setup-git' "$LOG"; then
  bad "03-repos.sh stops when GitHub is signed out: wrote or configured before stopping" "$(cat "$LOG")"
else
  ok "03-repos.sh stops when GitHub is signed out, naming the owner's step"
fi

fresh_home
# The repos exist, so the sign-in check is the only thing left to stop it.
mkdir -p "$T/home/Workspace/app" "$T/home/Workspace/api"
if out=$(run STUB_CLAUDE_AUTH=out bash "$REPO/scripts/05-remote-control.sh" 2>&1); then
  bad "05-remote-control.sh stops when Claude is signed out: exited 0" "$out"
elif [[ $out != *"/login"* ]]; then
  bad "05-remote-control.sh stops when Claude is signed out: owner's step not named" "$out"
elif [ -e "$T/home/.config/systemd/user/claude-rc@.service" ] || grep -q '^systemctl' "$LOG"; then
  bad "05-remote-control.sh stops when Claude is signed out: wrote a unit before stopping" "$(cat "$LOG")"
else
  ok "05-remote-control.sh stops when Claude is signed out, naming the owner's step"
fi

fresh_home
mkdir -p "$T/home/Workspace/app" "$T/home/Workspace/api"
if out=$(run STUB_LINGER=no bash "$REPO/scripts/05-remote-control.sh" 2>&1); then
  bad "05-remote-control.sh stops when lingering is off: exited 0" "$out"
elif [[ $out != *"lingering is off"* ]] || [ -e "$T/home/.config/systemd/user/claude-rc@.service" ]; then
  bad "05-remote-control.sh stops when lingering is off, before writing a unit" "$out"
else
  ok "05-remote-control.sh stops when lingering is off, before writing a unit"
fi

fresh_home
rc="$T/home/.config/claude-rc"
mkdir -p "$T/home/Workspace/app" "$rc"
printf '{ "agent": "writer" }\n' >"$rc/app.json"
echo writer >"$rc/app.started-agent"
touch -d '2020-01-01' "$rc/app.json"
out=$(run REPOS="app=org/app" RC_REPOS="app:writer" STUB_ACTIVE=yes \
  STUB_PS_ARGS="claude remote-control --spawn same-dir --name app --settings $rc/app.json" \
  bash "$REPO/scripts/05-remote-control.sh" 2>&1) || true
if [[ $out != *"app: running, unchanged"* ]] || grep -q 'restart' "$LOG" || [ "$(stat -c %Y "$rc/app.json")" != "$(date -d 2020-01-01 +%s)" ]; then
  bad "05-remote-control.sh leaves an unchanged server and its settings file alone" "$out"
else
  ok "05-remote-control.sh leaves an unchanged server and its settings file alone"
fi

# ---- 03-repos.sh --clone-only ------------------------------------------------

fresh_home
if ! out=$(run bash "$REPO/scripts/03-repos.sh" --clone-only 2>&1); then
  bad "03-repos.sh --clone-only: exited non-zero" "$out"
elif [ ! -d "$T/home/Workspace/app/.git" ] || [ ! -d "$T/home/Workspace/api/.git" ]; then
  bad "03-repos.sh --clone-only: did not clone" "$out"
elif grep -qE '^(npm|pnpm|bun) |^uv sync' "$LOG"; then
  bad "03-repos.sh --clone-only: ran an install" "$(cat "$LOG")"
else
  ok "03-repos.sh --clone-only clones and runs no install"
fi
: >"$LOG"
out=$(run bash "$REPO/scripts/03-repos.sh" 2>&1 || true)
if grep -q '^npm ci' "$LOG" && grep -q '^uv sync --frozen' "$LOG"; then
  ok "03-repos.sh without --clone-only installs by lockfile"
else
  bad "03-repos.sh without --clone-only installs by lockfile" "$out"
fi
: >"$LOG"
if out=$(run STUB_GIT_PULL=1 bash "$REPO/scripts/03-repos.sh" 2>&1); then
  bad "03-repos.sh stops on a failed pull: exited 0" "$out"
elif [[ $out != *"app: git pull --ff-only failed"* ]] || grep -qE '^(npm|pnpm|bun) |^uv sync' "$LOG"; then
  bad "03-repos.sh names a failed pull and installs nothing on top of it" "$out"
else
  ok "03-repos.sh names a failed pull and installs nothing on top of it"
fi

# ---- laptop/push.sh ----------------------------------------------------------

SENTINEL=SENTINEL999
KEYS="HEADERKEY111 QUERYKEY222 ENVKEY333 $SENTINEL"

push_fixture() {
  fresh_home
  local h="$T/home"
  mkdir -p "$h/.claude/skills/good" "$h/.claude/projects/p" "$T/elsewhere/linked-skill"
  cat >"$h/.claude.json" <<JSON
{
  "mcpServers": {
    "http-header": {"type": "http", "url": "https://h.example/mcp", "headers": {"Authorization": "Bearer HEADERKEY111"}},
    "http-query": {"type": "http", "url": "https://q.example/mcp?api_key=QUERYKEY222"},
    "stdio-env": {"type": "stdio", "command": "npx", "args": ["-y", "some-server"], "env": {"TOKEN": "ENVKEY333"}},
    "mac-path": {"type": "stdio", "command": "/Users/someone/bin/server", "args": [], "env": {}},
    "not-chosen": {"type": "http", "url": "https://n.example/mcp", "headers": {"X-Key": "$SENTINEL"}}
  },
  "projects": {"/Users/someone/proj": {"mcpServers": {"proj-server": {"type": "http", "url": "https://p.example/mcp"}}}}
}
JSON
  printf '# Instructions\n@~/somewhere/else.md\n' >"$h/.claude/CLAUDE.md"
  echo '{}' >"$h/.claude/settings.json"
  echo "a skill" >"$h/.claude/skills/good/SKILL.md"
  ln -s "$h/.claude.json" "$h/.claude/skills/good/leak"
  echo "notes kept elsewhere" >"$T/elsewhere/notes.md"
  ln -s "$T/elsewhere/notes.md" "$h/.claude/skills/good/notes"
  mkdir -p "$h/.ssh"
  echo "$SENTINEL private key" >"$h/.ssh/id_test"
  ln "$h/.ssh/id_test" "$h/.claude/skills/good/sshlink"
  echo "$SENTINEL commands" >"$T/elsewhere/fish_history"
  ln -s "$T/elsewhere/fish_history" "$h/.claude/skills/good/fishlink"
  mkdir -p "$h/.claude/skills/git-history"
  echo "a skill about history" >"$h/.claude/skills/git-history/SKILL.md"
  echo "a linked skill" >"$T/elsewhere/linked-skill/SKILL.md"
  ln -s "$T/elsewhere/linked-skill" "$h/.claude/skills/linked"
  echo "$SENTINEL" >"$h/.claude/projects/p/history.jsonl"
  printf '[user]\n\tname = Test Owner\n\temail = owner@example.com\n' >"$h/.gitconfig"
}

ssh_call_with() { # prints the number of the first ssh call whose arguments hold $1
  { grep -l -- "$1" "$T"/ssh/*.args 2>/dev/null || true; } | head -1 | xargs -r basename | cut -d. -f1
}

push_fixture
out=$(printf 'yes\n' | run bash "$REPO/laptop/push.sh" agent@box --connectors http-header,http-query,stdio-env,mac-path 2>&1) || true
n=$(ssh_call_with 04-connectors.sh)
leaked=
for k in $KEYS; do [[ $out != *"$k"* ]] || leaked+="$k "; done
if [ -z "$n" ]; then
  bad "push.sh sends the chosen connectors: no call to 04-connectors.sh" "$out"
elif [ "$(jq -r 'keys | join(",")' "$T/ssh/$n.in")" != "http-header,http-query,mac-path,stdio-env" ]; then
  bad "push.sh sends exactly the chosen connectors" "$(jq -r 'keys | join(",")' "$T/ssh/$n.in")"
elif grep -l "$SENTINEL" "$T"/ssh/*.in >/dev/null 2>&1; then
  bad "push.sh never sends the server that was not chosen" "$(grep -l "$SENTINEL" "$T"/ssh/*.in)"
elif [ -n "$leaked" ]; then
  bad "push.sh prints no connector value" "printed: $leaked"
elif [[ $out != *"http-header"* || $out != *"stdio-env"* ]]; then
  bad "push.sh previews the chosen connector names" "$out"
else
  ok "push.sh sends only the chosen connectors, previews names and prints no value"
fi
CHOSEN_JSON="$T/chosen.json"
cp "$T/ssh/$n.in" "$CHOSEN_JSON" 2>/dev/null || echo '{}' >"$CHOSEN_JSON"
want=$(jq -S '.mcpServers | with_entries(select(.key | IN("http-header", "http-query", "stdio-env", "mac-path")))' "$T/home/.claude.json")
if [ "$(jq -S . "$CHOSEN_JSON" 2>/dev/null)" = "$want" ]; then
  ok "push.sh sends each chosen definition whole"
else
  bad "push.sh sends each chosen definition whole" "$(cat "$CHOSEN_JSON")"
fi

c=$(ssh_call_with tar)
members=
[ -z "$c" ] || members=$(tar -tf "$T/ssh/$c.in" 2>/dev/null || true)
if [ -z "$c" ]; then
  bad "push.sh copies the config: no archive sent" "$out"
elif ! grep -qx 'skills/linked/SKILL.md' <<<"$members" || ! grep -qx 'skills/good/SKILL.md' <<<"$members"; then
  bad "push.sh sends a symlinked skill under its own name" "$members"
elif grep -qx 'skills/good/leak' <<<"$members"; then
  bad "push.sh drops a link to a forbidden file" "$members"
elif [[ $out != *"skills/good/leak"* ]]; then
  bad "push.sh names the dropped link" "$out"
elif grep -qx 'skills/good/sshlink' <<<"$members" || [[ $out != *"skills/good/sshlink: has other hard links"* ]]; then
  bad "push.sh drops and names a hard link to a file in ~/.ssh" "$members"
elif grep -qx 'skills/good/fishlink' <<<"$members"; then
  bad "push.sh drops a link to a shell history file" "$members"
elif grep -q "$SENTINEL" "$T/ssh/$c.in"; then
  bad "push.sh sends no content of a forbidden file" "$members"
elif ! grep -qx 'skills/git-history/SKILL.md' <<<"$members"; then
  bad "push.sh sends a skill whose name holds 'history'" "$members"
elif [[ $out != *"@~/somewhere/else.md"* ]]; then
  bad "push.sh names an import from outside what was sent" "$out"
else
  ok "push.sh sends a symlinked skill, drops and names a link to ~/.claude.json, names an outside import"
fi

if [[ $out == *"skills/good/notes  -> $T/elsewhere/notes.md"* ]]; then
  ok "push.sh previews a symlink inside a skill with its target"
else
  bad "push.sh previews a symlink inside a skill with its target" "$out"
fi

push_fixture
out=$(printf 'yes\n' | run bash "$REPO/laptop/push.sh" agent@box --connectors none 2>&1) || true
n=$(ssh_call_with 04-connectors.sh)
if [ -z "$n" ] || [ "$(cat "$T/ssh/$n.in")" != "{}" ]; then
  bad "push.sh --connectors none sends no connector" "$out"
elif [ -z "$(ssh_call_with tar)" ]; then
  bad "push.sh --connectors none still copies the config" "$out"
else
  ok "push.sh --connectors none sends no connector"
fi

push_fixture
out=$(printf 'yes\n' | run bash "$REPO/laptop/push.sh" agent@box --connectors none --exclude "$T/home/.claude/skills/linked" 2>&1) || true
c=$(ssh_call_with tar)
members=
[ -z "$c" ] || members=$(tar -tf "$T/ssh/$c.in" 2>/dev/null || true)
if [ -z "$c" ] || grep -q '^skills/linked' <<<"$members" || [[ $out != *"skills/linked: excluded"* ]]; then
  bad "push.sh honours --exclude given as a full path" "$out"$'\n'"$members"
else
  ok "push.sh honours --exclude given as a full path"
fi

push_fixture
if out=$(printf 'yes\n' | run bash "$REPO/laptop/push.sh" agent@box --connectors none --exclude "$T/elsewhere" 2>&1); then
  bad "push.sh refuses an --exclude outside ~/.claude: exited 0" "$out"
elif [ -n "$(ls "$T/ssh" 2>/dev/null)" ] || [[ $out != *"is not under ~/.claude"* ]]; then
  bad "push.sh refuses an --exclude outside ~/.claude before sending anything" "$out"
else
  ok "push.sh refuses an --exclude outside ~/.claude before sending anything"
fi

push_fixture
out=$(printf 'yes\n' | run STUB_SSH_FAIL=tar bash "$REPO/laptop/push.sh" agent@box --connectors none 2>&1) || true
if [[ $out != *"copying the config failed"* ]] || [[ $out == *"Copied into"* ]]; then
  bad "push.sh reports a failed copy as failed" "$out"
else
  ok "push.sh reports a failed copy as failed"
fi

# A file replaced while the confirmation prompt is open is not the one previewed.
push_fixture
mkfifo "$T/answer"
run bash "$REPO/laptop/push.sh" agent@box --connectors none <"$T/answer" >"$T/push.out" 2>&1 &
push_pid=$!
exec 7>"$T/answer"
for _ in $(seq 40); do
  grep -q 'Send these to' "$T/push.out" 2>/dev/null && break
  sleep 0.25
done
rm "$T/home/.claude/skills/good/SKILL.md"
echo "a different file under the same name" >"$T/home/.claude/skills/good/SKILL.md"
echo yes >&7
exec 7>&-
wait "$push_pid" || true
rm -f "$T/answer"
if ! grep -q 'skills/good/SKILL.md changed after the preview' "$T/push.out" || grep -q 'Copied into' "$T/push.out"; then
  bad "push.sh stops when a file changed after the preview" "$(cat "$T/push.out")"
else
  ok "push.sh stops when a file changed after the preview"
fi

# A skill added while the confirmation prompt is open was never previewed.
push_fixture
mkfifo "$T/answer"
run bash "$REPO/laptop/push.sh" agent@box --connectors none <"$T/answer" >"$T/push.out" 2>&1 &
push_pid=$!
exec 7>"$T/answer"
for _ in $(seq 40); do
  grep -q 'Send these to' "$T/push.out" 2>/dev/null && break
  sleep 0.25
done
mkdir -p "$T/home/.claude/skills/late"
echo "added after the preview" >"$T/home/.claude/skills/late/SKILL.md"
echo yes >&7
exec 7>&-
wait "$push_pid" || true
rm -f "$T/answer"
c=$(ssh_call_with tar)
members=
[ -z "$c" ] || members=$(tar -tf "$T/ssh/$c.in" 2>/dev/null || true)
if [ -z "$c" ] || grep -q '^skills/late' <<<"$members"; then
  bad "push.sh sends only what the preview showed" "$(cat "$T/push.out")"$'\n'"$members"
else
  ok "push.sh sends only what the preview showed"
fi

push_fixture
out=$(printf 'no\n' | run bash "$REPO/laptop/push.sh" agent@box --connectors http-header 2>&1) || true
if [ -n "$(ls "$T/ssh" 2>/dev/null)" ]; then
  bad "push.sh sends nothing unless the answer is yes" "$out"
else
  ok "push.sh sends nothing unless the answer is yes"
fi

# ---- 04-connectors.sh --------------------------------------------------------

fresh_home
out=$(run bash "$REPO/scripts/04-connectors.sh" <"$CHOSEN_JSON" 2>&1) || true
leaked=
for k in $KEYS CLAUDEAIKEY444 DIAGKEY666 h.example q.example some-server; do [[ $out != *"$k"* ]] || leaked+="$k "; done
registered=$(find "$T/claude-registry" -mindepth 1 -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')
if [ "$registered" != "http-header http-query stdio-env " ]; then
  bad "04-connectors.sh registers the portable servers" "registered: $registered"$'\n'"$out"
elif [[ $out != *"mac-path: skipped"* ]]; then
  bad "04-connectors.sh skips and names the macOS-path server" "$out"
elif [ -n "$leaked" ]; then
  bad "04-connectors.sh prints no key, URL or command line" "printed: $leaked"$'\n'"$out"
elif [[ $out != *'claude mcp login "claude.ai Example" --no-browser'* ]]; then
  bad "04-connectors.sh names the claude.ai sign-in step" "$out"
elif [[ $out != *"claude.ai Broken: failed to connect"* ]]; then
  bad "04-connectors.sh prints a fixed label for a failed connection" "$out"
else
  ok "04-connectors.sh registers the portable servers, skips the macOS one, prints no value"
fi
# Content and modification time, so a remove and re-add of the same definition
# shows as a change.
registry_state() { { find "$T/claude-registry" -type f -printf '%f %T@\n' | sort && cat "$T"/claude-registry/*; } 2>/dev/null || true; }
before=$(registry_state)
jq '."stdio-env".command = "/Users/someone/bin/server"' "$CHOSEN_JSON" >"$T/rerun.json"
out=$(run bash "$REPO/scripts/04-connectors.sh" <"$T/rerun.json" 2>&1) || true
if [ "$(registry_state)" != "$before" ]; then
  bad "04-connectors.sh run twice leaves the existing registrations alone" "$out"
elif [ "$(grep -c 'already registered' <<<"$out")" != 3 ]; then
  bad "04-connectors.sh run twice names the existing registrations" "$out"
elif [[ $out != *"    http-header: connected"* || $out != *"    stdio-env: connected"* ]]; then
  bad "04-connectors.sh run twice still lists the existing registrations' status" "$out"
else
  ok "04-connectors.sh run twice leaves the existing registrations alone and names them"
fi

fresh_home
out=$(printf '{"bad": {"command": "x", "args": "SECRETARGS777"}, "bad2": {"command": "x", "args": [{"k": "SECRETARGS888"}]}}' |
  run bash "$REPO/scripts/04-connectors.sh" 2>&1) || true
if [[ $out == *SECRETARGS* ]] || [[ $out != *"bad: skipped – the definition is not in the form"* ]] ||
  [[ $out != *"bad2: skipped – the definition is not in the form"* ]] || [ -e "$T/claude-registry/bad" ] || [ -e "$T/claude-registry/bad2" ]; then
  bad "04-connectors.sh skips a malformed definition without printing it" "$out"
else
  ok "04-connectors.sh skips a malformed definition without printing it"
fi

# ---- keys: base and handover -------------------------------------------------

grant() { run bash -c '. "$1" && read_inputs && grant_operator_key' _ "$REPO/scripts/lib.sh" 2>&1; }

rm -rf "$T/state" "$T/run"
printf '%s\n' "$OTHERKEY" >"$T/keys/user_ak"
out=$(grant)
out2=$(grant)
if [ "$(grep -c -F "$OP_BLOB" "$T/keys/user_ak")" != 1 ]; then
  bad "base adds the operator's key exactly once over two runs" "$out"$'\n'"$out2"$'\n'"$(cat "$T/keys/user_ak")"
elif ! grep -qF "$OTHERKEY" "$T/keys/user_ak"; then
  bad "base leaves an unrelated key in place" "$(cat "$T/keys/user_ak")"
else
  ok "base adds the operator's key once and leaves an unrelated key"
fi
printf '# %s\n%s\n' "$OPKEY" "$OTHERKEY" >"$T/keys/user_ak"
out=$(grant)
if [ "$(grep -v '^#' "$T/keys/user_ak" | grep -c -F "$OP_BLOB")" != 1 ]; then
  bad "base adds the key when only a commented-out copy is there" "$out"$'\n'"$(cat "$T/keys/user_ak")"
else
  ok "base adds the key when only a commented-out copy is there"
fi
printf '%s ssh-ed25519 %s\n' "$OTHERKEY" "$OP_BLOB" >"$T/keys/user_ak"
out=$(grant)
if ! grep -qxF "$OPKEY" "$T/keys/user_ak"; then
  bad "base adds the key when another key's comment holds it" "$out"$'\n'"$(cat "$T/keys/user_ak")"
else
  ok "base adds the key when another key's comment holds it"
fi
# A directory where the key file should be: no write to it can succeed.
mkdir -p "$T/userkeys/akdir"
if out=$(run USER_AUTHORIZED_KEYS="$T/userkeys/akdir" bash -c '. "$1" && read_inputs && grant_operator_key' _ "$REPO/scripts/lib.sh" 2>&1); then
  bad "base stops when the box user's key file can't be written: exited 0" "$out"
elif [[ $out == *"added the operator's key"* ]]; then
  bad "base stops when the box user's key file can't be written" "$out"
else
  ok "base stops when the box user's key file can't be written"
fi
mkdir -p "$T/state"
touch "$T/state/handed-over"
printf '%s\n' "$OTHERKEY" >"$T/keys/user_ak"
out=$(grant)
if grep -qF "$OP_BLOB" "$T/keys/user_ak"; then
  bad "base adds no key once the box is handed over" "$out"
else
  ok "base adds no key once the box is handed over"
fi

handover_fixture() {
  rm -rf "$T/state" "$T/run" "$T/sshd/d"
  mkdir -p "$T/state" "$T/sshd/d"
  touch "$T/state/closed"
  printf '%s\n%s\n' "$OPKEY" "$OTHERKEY" >"$T/keys/root_ak"
  printf 'no-pty %s\n%s\n' "$OPKEY" "$OTHERKEY" >"$T/keys/user_ak"
  : >"$LOG"
}

handover_fixture
if ! out=$(run STUB_UID=0 bash "$REPO/scripts/06-handover.sh" 2>&1); then
  bad "handover runs after a confirmed close" "$out"
elif grep -qF "$OP_BLOB" "$T/keys/root_ak" "$T/keys/user_ak"; then
  bad "handover removes the operator's key from both files" "$(cat "$T/keys/root_ak" "$T/keys/user_ak")"
elif ! grep -qF "$OTHERKEY" "$T/keys/root_ak" || ! grep -qF "$OTHERKEY" "$T/keys/user_ak"; then
  bad "handover leaves an unrelated key in both files" "$(cat "$T/keys/root_ak" "$T/keys/user_ak")"
elif [[ $out != *"$OTHER_FP"* ]] || [[ $out == *"$OP_FP"* ]]; then
  bad "handover prints the remaining keys' fingerprints" "$out"
elif [[ $out == *someone-else* || $out == *operator@test* ]]; then
  bad "handover prints no key comment" "$out"
elif [[ $out == *"$OTHER_BLOB"* || $out == *"$OP_BLOB"* ]]; then
  bad "handover prints no key line" "$out"
elif [ ! -e "$T/state/handed-over" ]; then
  bad "handover leaves its marker" "$out"
else
  ok "handover removes the operator's key from both files, keeps the other, prints fingerprints only"
fi
printf '%s\n' "$OTHERKEY" >"$T/keys/user_ak"
grant >/dev/null
if grep -qF "$OP_BLOB" "$T/keys/user_ak"; then
  bad "after handover, base does not grant the operator's key again"
else
  ok "after handover, base does not grant the operator's key again"
fi

handover_fixture
chmod 555 "$T/keys"
if out=$(run STUB_UID=0 bash "$REPO/scripts/06-handover.sh" 2>&1); then
  bad "handover stops when a key file can't be rewritten: exited 0" "$out"
elif [[ $out != *"could not rewrite"* ]] || [[ $out == *"Handover done"* ]]; then
  bad "handover stops when a key file can't be rewritten" "$out"
else
  ok "handover stops when a key file can't be rewritten"
fi
chmod 755 "$T/keys"

handover_fixture
printf '%s\n' "$OPKEY" >"$T/userkeys/ak"
chmod 000 "$T/userkeys"
if out=$(run STUB_UID=0 USER_AUTHORIZED_KEYS="$T/userkeys/ak" bash "$REPO/scripts/06-handover.sh" 2>&1); then
  bad "handover stops when the box user's key file can't be read: exited 0" "$out"
elif [[ $out == *"Handover done"* ]]; then
  bad "handover stops when the box user's key file can't be read" "$out"
else
  ok "handover stops when the box user's key file can't be read"
fi
chmod 700 "$T/userkeys"
handover_fixture
printf '%s ssh-ed25519 %s\n' "$OTHERKEY" "$OP_BLOB" >"$T/keys/user_ak"
out=$(run STUB_UID=0 bash "$REPO/scripts/06-handover.sh" 2>&1) || true
if ! grep -qF "$OTHER_BLOB" "$T/keys/user_ak"; then
  bad "handover keeps a key whose comment holds the operator's key" "$out"
else
  ok "handover keeps a key whose comment holds the operator's key"
fi

handover_fixture
rm -f "$T/state/closed"
expect_refusal "handover refuses before a confirmed close" "the close has not been confirmed" STUB_UID=0 bash "$REPO/scripts/06-handover.sh"
handover_fixture
echo "PermitRootLogin yes" >"$T/sshd/d/50-image.conf"
expect_refusal "handover refuses while sshd allows a root login, naming the file" "$T/sshd/d/50-image.conf" \
  STUB_UID=0 STUB_SSHD_ROOT=yes bash "$REPO/scripts/06-handover.sh"
handover_fixture
echo "PasswordAuthentication yes" >"$T/sshd/d/50-image.conf"
expect_refusal "handover refuses while sshd allows a password, naming the file" \
  "allows passwordauthentication for root. The first file that sets it is $T/sshd/d/50-image.conf" \
  STUB_UID=0 STUB_SSHD_PASSWORD=yes bash "$REPO/scripts/06-handover.sh"

# ---- the lockdown's close ----------------------------------------------------

lock_free() { flock -n "$T/run/close.lock" true 2>/dev/null; }
wait_lock_free() {
  for _ in $(seq 60); do
    lock_free && return 0
    sleep 0.25
  done
  return 1
}
close_fixture() {
  rm -rf "$T/state" "$T/run" "$T/sshd/d"
  mkdir -p "$T/sshd/d"
  : >"$LOG"
}

close_fixture
# The second yes goes in only once the revert has run, which its ufw call shows.
revert_ran() {
  for _ in $(seq 40); do
    grep -q '^ufw --force disable' "$LOG" && return 0
    sleep 0.25
  done
}
out=$({ echo yes; revert_ran; echo yes; } | run STUB_UID=0 REVERT_AFTER=1 bash "$REPO/scripts/02-tailscale-lockdown.sh" close 2>&1) && rc=0 || rc=$?
wait_lock_free || true
if [ "$rc" -eq 0 ]; then
  bad "a yes after the revert has fired exits non-zero" "$out"
elif [[ $out != *"Public SSH is open again"* ]]; then
  bad "a yes after the revert has fired says public SSH is open again" "$out"
elif [ -e "$T/state/closed" ]; then
  bad "a yes after the revert has fired writes no marker" "$out"
elif [ -e "$T/sshd/d/99-tailscale.conf" ] || ! grep -q '^ufw --force disable' "$LOG"; then
  bad "the revert undid the close" "$(cat "$LOG")"
else
  ok "a yes after the revert has fired exits non-zero, says so and writes no marker"
fi

close_fixture
out=$({ echo yes; echo no; } | run STUB_UID=0 REVERT_AFTER=8 bash "$REPO/scripts/02-tailscale-lockdown.sh" close 2>&1) || true
# Two yeses, so a close that wrongly went ahead would confirm and exit 0.
if out2=$(printf 'yes\nyes\n' | run STUB_UID=0 REVERT_AFTER=8 bash "$REPO/scripts/02-tailscale-lockdown.sh" close 2>&1); then
  bad "a second close while a revert is armed refuses" "$out2"
elif [[ $out2 != *"still armed"* ]]; then
  bad "a second close while a revert is armed says why" "$out2"
else
  ok "a second close while a revert is armed refuses"
fi
mkdir -p "$T/state"
touch "$T/state/closed"
expect_refusal "a handover while a revert is armed refuses" "still armed" STUB_UID=0 bash "$REPO/scripts/06-handover.sh"
wait_lock_free || bad "the armed revert released its lock after running"

close_fixture
out=$({ echo yes; sleep 5; } | run STUB_UID=0 STUB_UFW_SLOW=1 REVERT_AFTER=1 bash "$REPO/scripts/02-tailscale-lockdown.sh" close 2>&1) && rc=0 || rc=$?
wait_lock_free || true
after_revert=$(sed -n '/^ufw --force disable/,$p' "$LOG" | grep -c '^ufw' || true)
if [ "$rc" -eq 0 ] || [[ $out != *"Public SSH is open again"* ]]; then
  bad "a revert that fires mid-close stops the close and says so" "$out"
elif ! grep -q '^ufw --force disable' "$LOG" || [ "$after_revert" != 1 ]; then
  bad "a revert that fires mid-close is the last to touch the firewall" "$(cat "$LOG")"
else
  ok "a revert that fires mid-close stops the close and is the last to touch the firewall"
fi

close_fixture
mkfifo "$T/close-answers"
run STUB_UID=0 REVERT_AFTER=1 bash "$REPO/scripts/02-tailscale-lockdown.sh" close <"$T/close-answers" >"$T/close1.out" 2>&1 &
close_pid=$!
exec 7>"$T/close-answers"
echo yes >&7
revert_ran
out2=$(echo no | run STUB_UID=0 bash "$REPO/scripts/02-tailscale-lockdown.sh" close 2>&1) || true
exec 7>&-
wait "$close_pid" || true
rm -f "$T/close-answers"
if [[ $out2 == *"still armed"* ]] || [[ $out2 != *"Aborting."* ]]; then
  bad "once the revert has run, a new close isn't refused while the first prompt is open" "$out2"
else
  ok "once the revert has run, a new close isn't refused while the first prompt is open"
fi

close_fixture
printf '%s\n%s\n' "$OPKEY" "$OTHERKEY" >"$T/keys/root_ak"
printf '%s\n%s\n' "$OPKEY" "$OTHERKEY" >"$T/keys/user_ak"
out=$({ echo yes; echo yes; } | run STUB_UID=0 REVERT_AFTER=20 bash "$REPO/scripts/02-tailscale-lockdown.sh" close 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] || [ ! -e "$T/state/closed" ]; then
  bad "a timely yes confirms the close and writes the marker" "$out"
elif ! out2=$(run STUB_UID=0 bash "$REPO/scripts/06-handover.sh" 2>&1); then
  bad "a handover straight after a confirmed close is not refused" "$out2"
else
  ok "a timely yes writes the marker, and a handover straight after is not refused"
fi
if grep -q '^apt' "$LOG"; then
  bad "the close runs no apt inside its revert window" "$(cat "$LOG")"
else
  ok "the close runs no apt inside its revert window"
fi
# The lock is free only once the revert job is gone, and only that job can revert.
if ! lock_free || [ ! -e "$T/sshd/d/99-tailscale.conf" ] || grep -q '^ufw --force disable' "$LOG"; then
  bad "a confirmed close is not reverted later" "$(cat "$LOG")"
else
  ok "a confirmed close is not reverted later"
fi

# ---- isolation ---------------------------------------------------------------

AFTER=$(watched)
if [ "$AFTER" = "$BEFORE" ]; then
  ok "nothing outside the temporary directory changed"
else
  bad "nothing outside the temporary directory changed" "$(diff <(echo "$BEFORE") <(echo "$AFTER"))"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
