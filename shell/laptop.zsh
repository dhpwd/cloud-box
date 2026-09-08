# Laptop-side shell helpers. Source this from ~/.zshrc.
#
# The first section is the laptop's half of the cloud box: the box's own
# helpers are written by scripts/cloud-box/05-tmux-and-shell.sh into
# ~/.bash_aliases. The second is file picking, which that script mirrors
# for bash on the box.

CLOUD_BOX="${CLOUD_BOX:-you@your-box.your-tailnet.ts.net}"   # user@MagicDNS name

# box          – back to the tmux session you were last in, like t on the box
#                (falls back to a plain shell when nothing is running)
# box <repo>   – that project's tmux session, created in its directory if gone,
#                falling back to ~/Workspace when the name is not a repo
#
# -D / attach -d detaches any other client first. mosh-server outlives a lost
# connection by design, so an abandoned session keeps its tmux client attached
# indefinitely – and tmux sizes a window to the smallest client watching it,
# so a forgotten 52-column connection shrinks the pane you are working in.
#
# Claude Code's auto theme asks the terminal for its background over OSC 11, and
# neither tmux nor mosh lets that reach Ghostty. COLORFGBG is its documented
# fallback, read once when claude starts, so compute it here from the Mac's
# current appearance and pass it across – Ghostty follows the system theme, so
# a static value would be wrong half the time. A claude already running when
# the Mac switches needs /theme; the box cannot tell it.
box() {
  local fgbg
  if defaults read -g AppleInterfaceStyle >/dev/null 2>&1; then fgbg='15;0'; else fgbg='0;15'; fi
  if [ -n "$1" ]; then
    mosh "$CLOUD_BOX" -- env COLORFGBG="$fgbg" bash -lc \
      "d=~/Workspace/$1; [ -d \"\$d\" ] || d=~/Workspace; exec tmux new -A -D -s \"$1\" -c \"\$d\""
  else
    mosh "$CLOUD_BOX" -- env COLORFGBG="$fgbg" bash -lc \
      'tmux attach -d 2>/dev/null || { echo "nothing to attach to – plain shell:"; tmux ls 2>/dev/null; exec bash -l; }'
  fi
}

# mosh cannot forward ports, so a localhost-callback OAuth flow, scp, or reading
# long output with the terminal's own scrollback all need plain SSH:
#   ssh -t "$CLOUD_BOX"

# boxtunnel <port> – forward one port to the box for an OAuth callback, and hold
# it open until interrupted. See the auth-mcp-on-box skill for the full sequence.
boxtunnel() {
  [ -n "$1" ] || { echo "usage: boxtunnel <port>"; return 1; }
  echo "forwarding localhost:$1 to the box – Ctrl-C when the flow completes"
  ssh -N -L "$1:localhost:$1" "$CLOUD_BOX"
}

# boximg – push the image on the Mac's clipboard into the box's clipboard, so
# Ctrl-V in a Claude Code session there attaches it. Claude Code reads the
# clipboard of the machine it runs on (xclip on Linux), and nothing between
# Ghostty and tmux carries an image across, so it has to be sent first. The
# box side is an Xvfb display that exists only to hold the selection, set up
# by 05-tmux-and-shell.sh. Needs pngpaste from Homebrew. xclip forks to serve
# the selection and would keep ssh waiting on its fds, hence the redirects.
boximg() {
  local f
  f=$(mktemp -t boximg) || return
  pngpaste "$f" || { rm -f "$f"; return 1; }
  ssh "$CLOUD_BOX" 'DISPLAY=:99 xclip -selection clipboard -t image/png -i >/dev/null 2>&1' < "$f" \
    && echo "image sent – Ctrl-V in the box session"
  rm -f "$f"
}

# --- Git ------------------------------------------------------------------
# sweep – every repo under ~/Workspace on one line each: fetch, then branch
# with ahead/behind against the remote and a count of uncommitted files. Run
# on arriving at either machine, and before leaving the laptop – anything
# ahead or dirty here is invisible to the box. Mirrored in ~/.bash_aliases.
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

# starship: branch, dirty count and ahead/behind in the prompt, so the state
# of a checkout is visible without running anything. Config in starship.toml,
# symlinked to ~/.config by install.sh.
command -v starship >/dev/null && eval "$(starship init zsh)"

# --- Editing --------------------------------------------------------------
# micro for prose: no modes, Ctrl-S saves, mouse works. Soft wrap is set in
# ~/.config/micro/settings.json, which nothing here manages.
command -v micro >/dev/null && export EDITOR=micro

# --- File picking ---------------------------------------------------------
# Needs fzf, fd and bat from Homebrew. Guarded so a fresh laptop that has run
# install.sh but not brew yet starts its shell without errors.
if command -v fzf >/dev/null; then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  # CTRL-T inserts a file path at the cursor, CTRL-R fuzzy-searches history.
  # The tty test keeps `zsh -i -c` from complaining that it has no zle.
  [[ -t 1 ]] && source <(fzf --zsh)

  # fp [dir] – pick a file, copy its absolute path to the clipboard and print it
  fp() {
    local f
    f=$(fd --type f --hidden --exclude .git . "${1:-.}" | fzf --preview 'bat --color=always --style=plain {}')
    [[ -n $f ]] && printf '%s' "${f:a}" | pbcopy && echo "${f:a}"
  }

  # ff <pattern> – list matching file paths without the picker
  alias ff='fd'
fi
