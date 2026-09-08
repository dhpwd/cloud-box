#!/usr/bin/env bash
# Step 5 – tmux, project sessions, kill switch. Runs as the box user.
set -euo pipefail

# Synchronised output (DECSET 2026) landed in tmux 3.7. Without it Claude Code's
# TUI flickers. 01-base.sh builds 3.7 from source because Debian 13 ships 3.5a.
V=$(tmux -V | grep -oE '[0-9]+\.[0-9]+')
awk -v v="$V" 'BEGIN{ if (v+0 < 3.7) print "WARNING: tmux " v " < 3.7 – no synchronised output, the TUI will flicker" }'

cat > "$HOME/.tmux.conf" <<'CONF'
set -g mouse on
set -g history-limit 50000
set -g default-terminal "tmux-256color"
set -as terminal-features ",*:RGB"
set -g escape-time 10
set -g focus-events on
set -g status-left-length 30
set -g allow-passthrough on
# Default is "external", which forwards tmux's own copy-mode yanks but blocks
# programs inside tmux from writing the clipboard. "on" allows both, which is
# what fp needs to push a path back to the Mac over OSC 52.
set -g set-clipboard on
# tmux's own clipboard writes (copy-mode yanks, mouse selections, load-buffer
# -w) leave with an empty OSC 52 selector, which mosh drops. Pin the "c"
# selector so they reach the Mac like fp's do. The usual recipe drops %p1, but
# tmux 3.7 against ncurses 6.5 expands Ms with tiparm_s, which returns NULL for
# a string that skips a parameter, and tmux then emits nothing – so %p1 is
# consumed at zero width instead.
set -as terminal-overrides ',*:Ms=\E]52;%p1%.0sc;%p2%s\a'
set -ga update-environment COLORFGBG
# Splits like a laptop terminal: - below, | beside, and the new pane opens in
# the current pane's directory rather than the one the session started in.
# The stock " and % bindings stay.
bind - split-window -v -c "#{pane_current_path}"
bind | split-window -h -c "#{pane_current_path}"
CONF

# One session per project, named after the directory with dots swapped for
# dashes so fidero.js and fidero.com do not collide on a bare "fidero".
#   mosh dan@<magicdns-name> -- tmux attach -t fidero-os
# One session per project, plus a general one at ~/Workspace for dispatching
# background jobs and reading `claude agents`. That does not need tmux for
# persistence – the supervisor outlives the connection – but mosh has no
# scrollback, so tmux's copy mode is the only way to read back what happened.
tmux new-session -d -s agents -c "$HOME/Workspace" 2>/dev/null || true
# The projects that get a session at build time – edit to taste.
for p in fidero-os fidero-engine fidero.js fidero.com cli-agents; do
  d="$HOME/Workspace/$p"
  [ -d "$d" ] || continue
  tmux new-session -d -s "${p//./-}" -c "$d" 2>/dev/null || true
done
tmux ls || true

# Claude Code's image paste (Ctrl-V) shells out to xclip on the machine it runs
# on, and xclip needs an X display. There is no desktop here, so a 16-pixel Xvfb
# stands in as a clipboard holder: boximg on the laptop pushes the Mac's
# clipboard image into it over ssh, and the claude wrapper in ~/.bash_aliases
# points DISPLAY at it – only there, so micro's clipboard and Playwright keep
# behaving as they do now. Comes back at boot once 06-supervisor.sh has enabled
# lingering. xvfb and xclip are installed by 01-base.sh.
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/xvfb-clipboard.service" <<'UNIT'
[Unit]
Description=Xvfb on :99 as a clipboard holder for Claude Code image paste

[Service]
ExecStart=/usr/bin/Xvfb :99 -screen 0 16x16x24 -nolisten tcp
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now xvfb-clipboard.service

# Environment goes in ~/.profile, which login shells read and which exports
# through to everything below it.
grep -q 'COLORFGBG' "$HOME/.profile" 2>/dev/null || cat >> "$HOME/.profile" <<'CONF'

# Cloud box
# Claude Code's auto theme queries the terminal background with OSC 11, and
# nothing here answers it: tmux neither replies for a pane nor passes the
# outer terminal's reply back, and mosh drops the query anyway. COLORFGBG is
# the documented fallback, read once when claude starts. This is only a dark
# default for clients that cannot compute one (the phone); the laptop's box()
# passes the live value from macOS appearance, tmux copies it into the session
# environment on attach, and the claude wrapper in ~/.bash_aliases pulls it
# from there at launch.
export COLORFGBG="${COLORFGBG:-15;0}"
CONF

# Claude Code caps itself at 256 colours whenever TMUX is set unless told
# otherwise. tmux advertises RGB (terminal-features) and mosh 1.4 carries true
# colour, so the cap only makes accent colours differ from the laptop.
grep -q 'CLAUDE_CODE_TMUX_TRUECOLOR' "$HOME/.profile" 2>/dev/null || cat >> "$HOME/.profile" <<'CONF'
export CLAUDE_CODE_TMUX_TRUECOLOR=1
CONF

grep -q 'EDITOR=' "$HOME/.profile" 2>/dev/null || cat >> "$HOME/.profile" <<'CONF'
# micro for prose: no modes, Ctrl-S saves, mouse works through tmux.
export EDITOR=micro
CONF

# Soft wrap so a blog paragraph reads as a paragraph. micro writes in-editor
# `set` changes back to this file, and this script overwrites them.
# clipboard=terminal makes Ctrl-C emit OSC 52 with the `c` selector, which tmux
# forwards and mosh relays to the Mac. The default `external` shells out to
# xclip, which has no DISPLAY here (only the claude wrapper sets one), so micro
# falls back to a buffer of its own and nothing leaves the editor.
# The default colourscheme (monokai) paints its own dark background, black on a
# light Ghostty. `simple` uses only the 16 ANSI colours and no background, so
# it follows whatever the terminal is showing, live, with no COLORFGBG needed.
mkdir -p "$HOME/.config/micro"
cat > "$HOME/.config/micro/settings.json" <<'CONF'
{
    "clipboard": "terminal",
    "colorscheme": "simple",
    "softwrap": true,
    "wordwrap": true
}
CONF

# Aliases and functions go in ~/.bash_aliases, NOT ~/.profile. Only login shells
# read ~/.profile, and aliases are not inherited by child shells the way exported
# variables are, so helpers defined there are missing inside tmux panes. Debian's
# stock ~/.bashrc sources ~/.bash_aliases for every interactive shell, login or
# not, which covers both.
cat > "$HOME/.bash_aliases" <<'CONF'
# Shell helpers for the cloud box.

# t          – back to the session you were last in
# t <repo>   – that project's session, created in its directory if gone
#
# -D / attach -d detaches any other client first, so an abandoned mosh session
# does not sit attached and shrink the window to its own size.
t() {
  [ -n "$TMUX" ] && { echo "already inside tmux"; return 1; }
  if [ -n "$1" ]; then
    # Root the session at the matching repo, or at ~/Workspace when there is no
    # such directory – that covers a general session like `t agents`, and stops
    # a typo creating one in a path that does not exist.
    local d="$HOME/Workspace/$1"
    [ -d "$d" ] || d="$HOME/Workspace"
    tmux new -A -D -s "$1" -c "$d"
  else
    tmux attach -d 2>/dev/null || { echo "nothing to attach to:"; tmux ls 2>/dev/null || echo "  no sessions running"; }
  fi
}

# Agent launchers for my custom agents, matching the laptop. Yours will differ.
alias emma="claude --agent emma"
alias toby="claude --agent toby"
alias mia="claude --agent mia"

# ben is vault-scoped (fidero-os/.claude/agents), so it only resolves from there.
# The subshell leaves the caller's working directory alone.
ben() { (cd ~/Workspace/fidero-os && claude --agent ben "$@"); }

# Stops every agent process without touching the tmux sessions.
alias killagents="pkill -u $USER -f 'claude|codex|gemini'"

# Claude Code reads COLORFGBG once, when it starts. tmux copies the attaching
# client's value into the session environment (update-environment), but that
# only reaches panes created after the attach – a shell already running keeps
# whatever it started with. Pull it from the session at launch so a claude
# started from any pane follows the most recent attach. The agent aliases
# above go through this too. The case guard keeps the ~/.profile default when
# the session holds no value at all.
# DISPLAY points Ctrl-V's xclip at the Xvfb clipboard holder (see the unit
# above). Set here rather than in ~/.profile so nothing else picks it up.
claude() {
  if [ -n "$TMUX" ]; then
    local v
    v=$(tmux show-environment -s COLORFGBG 2>/dev/null)
    case $v in COLORFGBG=*) eval "$v" ;; esac
  fi
  DISPLAY=:99 command claude "$@"
}

# sweep – every repo under ~/Workspace on one line each: fetch, then branch
# with ahead/behind against the remote and a count of uncommitted files. Run
# on arriving after time away, and weekly. Mirrors shell/laptop.zsh.
# sweep was an alias before it was a function: a shell that still holds the
# alias cannot parse the definition, so drop it first for re-sourcing.
unalias sweep 2>/dev/null
sweep() {
  local d name line dirty
  for d in "$HOME"/Workspace/*/; do
    [ -d "$d/.git" ] || continue
    name=$(basename "$d")
    git -C "$d" fetch -q --prune 2>/dev/null || name="$name (offline)"
    line=$(git -C "$d" status -sb | head -1)
    dirty=$(git -C "$d" status --porcelain | wc -l | tr -d ' ')
    printf '%-22s %s' "$name" "$line"
    [ "$dirty" != 0 ] && printf '  %s dirty' "$dirty"
    printf '\n'
  done
}

# File picking, matching the laptop's ~/.zshrc. Debian names the binaries
# fdfind and batcat to avoid clashes with fdclone and bacula-console; the
# aliases restore the upstream names so muscle memory carries across.
# FZF_DEFAULT_COMMAND lives here rather than ~/.profile because it is only ever
# read by an interactive fzf, and ~/.bash_aliases reaches every interactive
# shell including non-login tmux panes.
alias fd='fdfind'
# bat and glow pick light or dark by asking the terminal over OSC 11, which
# neither tmux nor mosh passes on. glow then falls back to COLORFGBG, but from
# this shell's copy, which is whichever attach the pane was created under; bat
# ignores it and always lands on the dark theme. Both go through the tmux
# session's value instead – the most recent attach, the same rule as the
# claude wrapper above. bat was an alias before it was a function, so drop
# that first for re-sourcing.
_fgbg() {
  local s
  if [ -n "$TMUX" ]; then
    s=$(tmux show-environment COLORFGBG 2>/dev/null)
    case $s in COLORFGBG=*) echo "${s#*=}"; return ;; esac
  fi
  echo "$COLORFGBG"
}
_scheme() {
  local v; v=$(_fgbg)
  case ${v##*;} in 7|15) echo light ;; *) echo dark ;; esac
}
_bat_theme() {
  case $(_scheme) in light) echo 'Monokai Extended Light' ;; *) echo 'Monokai Extended' ;; esac
}
unalias bat 2>/dev/null
bat() { batcat --theme="$(_bat_theme)" "$@"; }
glow() { COLORFGBG=$(_fgbg) command glow "$@"; }
export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
# CTRL-T inserts a file path at the cursor, CTRL-R fuzzy-searches history.
[ -t 1 ] && eval "$(fzf --bash)"
# fzf defaults to its 256-colour dark scheme and never detects the background.
# The bindings above run fzf through the shell, so a function covers Ctrl-T,
# Ctrl-R and fp. Defined after the eval so `fzf --bash` gets the real binary.
fzf() { command fzf --color="$(_scheme)" "$@"; }

# fp [dir] – pick a file, print its absolute path and put it on the Mac's
# clipboard. There is no X or Wayland here, so the path travels back as an
# OSC 52 escape: tmux forwards it (set-clipboard on), mosh 1.4 relays it but
# only for the "c" selector, and Ghostty accepts clipboard writes by default.
fp() {
  local f
  f=$(fdfind --type f --hidden --exclude .git . "${1:-.}" | fzf --preview "batcat --color=always --style=plain --theme='$(_bat_theme)' {}") || return
  [ -n "$f" ] || return
  f=$(readlink -f "$f")
  printf '\033]52;c;%s\a' "$(printf '%s' "$f" | base64 -w0)"
  printf '%s\n' "$f"
}

# ff <pattern> – list matching file paths without the picker
alias ff='fdfind'

# starship: branch, dirty count and ahead/behind in the prompt of every pane.
# Config is ~/.config/starship.toml, symlinked into cli-agents by install.sh.
command -v starship >/dev/null && eval "$(starship init bash)"
CONF

echo "Done. Open a new shell, or run: . ~/.bash_aliases"
