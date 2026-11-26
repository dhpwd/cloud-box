#!/usr/bin/env bash
# Step 7 – an always-on Remote Control server for each repo in RC_REPOS, so the
# Claude desktop and phone apps can start and continue sessions on the box.
# Runs as the box user, after the trust step (README, step 6). Safe to run
# again: it restarts only the servers whose settings changed.
#
# Each server is a systemd user unit, claude-rc@<repo>.service, rooted in
# ~/Workspace/<repo>. It polls Anthropic over outbound HTTPS, shows in the
# apps, and starts a session in its folder each time one is opened there.
#
# A repo given as <repo>:<agent> has every session its server starts run as
# that agent: the `agent` settings key, passed as --settings from
# ~/.config/claude-rc/<repo>.json. No --permission-mode is passed, so sessions
# follow defaultMode in the owner's settings.json.
#
# Under systemd the server has no terminal, so it can't ask its first-run
# questions (trust, the one-time confirmation, the spawn mode) and exits
# instead. The trust step answers the first two, and --spawn is always passed.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
read_inputs
require_box_user

command -v claude >/dev/null || die "claude is not on PATH – run 01-base.sh first"
# Signed out, `claude auth status` exits 1 and prints "loggedIn": false.
if ! auth=$(claude auth status 2>/dev/null) ||
  [ "$(printf '%s' "$auth" | jq -r '.loggedIn' 2>/dev/null)" != true ]; then
  die "Claude Code is not signed in. Owner's step: run claude, then /login, open the URL it prints and paste the code back. Then run this again."
fi
[ "$(loginctl show-user "$BOX_USER" --property=Linger --value 2>/dev/null)" = yes ] ||
  die "lingering is off for $BOX_USER, so the servers would stop at logout. Run 01-base.sh as root, which turns it on."

for r in "${RC_DIRS[@]}"; do
  [ -d "$HOME/Workspace/$r" ] || die "$HOME/Workspace/$r is missing – run 03-repos.sh first"
done

conf="$HOME/.config/claude-rc"
units="$HOME/.config/systemd/user"
mkdir -p "$conf" "$units"

flags="--spawn $RC_SPAWN"
[ -z "$RC_CAPACITY" ] || flags+=" --capacity $RC_CAPACITY"

# bash -lc, because nvm and ~/.local/bin reach PATH only through ~/.profile.
# $$ is a literal $ in a unit file.
{
  cat <<'UNIT'
[Unit]
Description=Claude Code Remote Control server for ~/Workspace/%i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/Workspace/%i
UNIT
  printf '%s\n' "ExecStart=/bin/bash -lc 'f=%h/.config/claude-rc/%i.json; if [ -f \"\$\$f\" ]; then exec claude remote-control $flags --name %i --settings \"\$\$f\"; else exec claude remote-control $flags --name %i; fi'"
  cat <<'UNIT'
Restart=always
RestartSec=30
# The server redraws its status screen on stdout continuously. Errors still
# reach the journal on stderr.
StandardOutput=null

[Install]
WantedBy=default.target
UNIT
} >"$units/claude-rc@.service"
systemctl --user daemon-reload

started=
for i in "${!RC_DIRS[@]}"; do
  r=${RC_DIRS[$i]}
  agent=${RC_AGENTS[$i]}
  unit="claude-rc@$r.service"

  # The server reads its arguments and settings file once, at start, and once
  # the file changes it starts no session until it is restarted. So the file is
  # written only when its content differs, and any write means a restart.
  # Sessions run as this user and can edit the file too: the next run of this
  # script puts it back and restarts the server.
  f="$conf/$r.json"
  stamp="$conf/$r.started-agent"
  wrote=
  if [ -n "$agent" ]; then
    desired=$(printf '{ "agent": "%s" }' "$agent")
    if [ "$(cat "$f" 2>/dev/null)" != "$desired" ]; then
      rm -f "$stamp"
      printf '%s\n' "$desired" >"$f"
      wrote=1
    fi
  elif [ -e "$f" ]; then
    rm -f "$stamp" "$f"
    wrote=1
  fi

  # A daemon-reload doesn't reach a running process, so the arguments are
  # compared on the running process itself. The agent it was started with is
  # recorded once it has started, and the record is dropped before the settings
  # file is rewritten, so a run that stopped before its restart still restarts.
  want="claude remote-control $flags --name $r"
  [ -z "$agent" ] || want+=" --settings $f"
  systemctl --user enable --quiet "$unit"
  if systemctl --user is-active --quiet "$unit"; then
    pid=$(systemctl --user show -p MainPID --value "$unit")
    have=$(ps -ww -o args= -p "$pid" 2>/dev/null || true)
    if [ -z "$wrote" ] && [ "$have" = "$want" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$agent" ]; then
      echo "==> $r: running, unchanged"
      continue
    fi
    echo "==> $r: settings changed – restarting its server. Its open sessions stop until each is next opened in the app, and a turn running now is lost"
    systemctl --user restart "$unit"
  else
    echo "==> $r: starting"
    systemctl --user start "$unit"
  fi
  printf '%s\n' "$agent" >"$stamp"
  started=1
done

while read -r u _; do
  r=${u#claude-rc@}
  r=${r%.service}
  in_list "$r" "${RC_DIRS[@]}" ||
    echo "    note: claude-rc@$r is set up but not in RC_REPOS, and an enabled one starts again at boot. To remove it: systemctl --user disable --now claude-rc@$r"
done < <(
  {
    systemctl --user list-units 'claude-rc@*' --all --plain --no-legend 2>/dev/null
    # Enabled on disk starts at the next boot, loaded now or not.
    for f in "$HOME"/.config/systemd/user/*.wants/claude-rc@*.service; do
      [ ! -L "$f" ] || echo "${f##*/}"
    done
  } | awk '!seen[$1]++'
)

if [ -n "$started" ]; then
  echo "==> Waiting 20s, then checking the servers stayed up"
  sleep 20
fi

down=0
for r in "${RC_DIRS[@]}"; do
  unit="claude-rc@$r.service"
  if systemctl --user is-active --quiet "$unit"; then
    echo "    $r: active"
    continue
  fi
  down=1
  log=$(journalctl --user -u "$unit" -n 30 --no-pager -o cat 2>/dev/null || true)
  echo "!! $r: not active" >&2
  case $log in
    *"Workspace not trusted"* | *"Enable Remote Control?"*)
      echo "   The trust step was missed for $r. As $BOX_USER, in a terminal:" >&2
      echo "     cd ~/Workspace/$r && claude remote-control --no-create-session-in-dir --spawn $RC_SPAWN" >&2
      echo "   answer y to each question, wait until it says it is running, press Ctrl+C, then run this again." >&2
      ;;
    *"disabled by your organization's policy"*)
      echo "   Owner's step: Remote Control is off for the owner's Claude organisation. An Owner of it turns on" >&2
      echo "   the Remote Control toggle at https://claude.ai/admin-settings/claude-code, then run this again." >&2
      ;;
    *)
      echo "   The last lines of its journal:" >&2
      printf '%s\n' "$log" | sed 's/^/     /' >&2
      echo "   First try the trust step for $r (README, step 6), then run this again. Then: claude doctor" >&2
      echo "   (the server's standard output goes nowhere, so a question it asked there is not in the journal)" >&2
      ;;
  esac
done
[ "$down" -eq 0 ] || exit 1

cat <<'MSG'

In the Claude app: Code → new session → pick the box's environment for the repo.
Every server opened one session when it started. Ending those in the app frees
their memory (README, step 8).
Logs: journalctl --user -u claude-rc@<repo> -f
MSG
