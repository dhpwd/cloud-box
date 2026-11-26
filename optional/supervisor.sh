#!/usr/bin/env bash
# Step 6 – background-job supervisor across reboots. Runs as the box user.
#
# `claude --bg` and `claude agents` run against a per-user daemon that outlives
# the SSH session that started it. The daemon does not come back after a reboot,
# so this installs a user-level oneshot that touches it at boot. Check the roster
# after any restart.
#
# Codex has no equivalent supervisor and Gemini CLI hangs without a TTY – both
# stay in tmux windows. This covers Claude only.
#
# The unit runs bash, not sh: nvm's installer only writes to ~/.bashrc, and dash
# as a login shell reads ~/.profile, so `claude` would not be on PATH under sh.
#
# UNVERIFIED: `claude agents --json` is documented as printing the roster and
# exiting. Whether that alone starts a supervisor when none is running is not
# documented. Check on the first reboot – `claude daemon status` before and after
# – and if it does not, swap ExecStart for something that does.
set -euo pipefail

command -v claude >/dev/null || { echo "claude not on PATH – install and /login Claude Code first" >&2; exit 1; }

mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/claude-supervisor.service" <<'UNIT'
[Unit]
Description=Start the Claude Code background-job supervisor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -lc 'claude agents --json >/dev/null'

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now claude-supervisor.service

# Without lingering, the user manager stops at logout and the unit never runs at
# boot. Needs root, so skip it when already on or when there is no TTY for sudo.
if [ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)" = "yes" ]; then
  echo "    lingering already enabled"
elif [ -t 0 ]; then
  sudo loginctl enable-linger "$USER"
else
  echo "    !! lingering not enabled and no TTY – run: sudo loginctl enable-linger $USER"
fi

systemctl --user --no-pager status claude-supervisor.service || true

cat <<'MSG'

Supervisor touched at boot. Verify after the next reboot with:
  claude daemon status && claude agents

If the roster is empty and no daemon is running, `--json` does not start one –
change ExecStart to a command that does.

Unattended jobs: dispatch with `claude --bg` or from `claude agents`, not a bare
`claude` in a tmux window. Idle sessions are torn down after about an hour and
resume from disk on attach.
MSG
