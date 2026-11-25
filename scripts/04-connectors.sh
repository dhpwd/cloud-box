#!/usr/bin/env bash
# Step 5, box side – registers the connectors laptop/push.sh sends, at user
# scope. Runs as the box user, reading one JSON object on standard input: server
# name to definition, in the form ~/.claude.json holds them.
#
#   laptop/push.sh runs it over SSH. By hand:  ./04-connectors.sh [--replace] < servers.json
#
# A definition can hold a key in a header, an env value or a URL's query string,
# so the input stays in memory (pipes, never a file) and nothing printed says
# more about a server than its name and a status.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
read_inputs
require_box_user

REPLACE=
case "${1:-}" in
  "") ;;
  --replace) REPLACE=1 ;;
  *) die "usage: ${0##*/} [--replace] < servers.json" ;;
esac

command -v claude >/dev/null || die "claude is not on PATH – run 01-base.sh first"
cd "$HOME"

input=$(cat)
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 ||
  die "standard input is not one JSON object of server definitions"
mapfile -t names < <(printf '%s' "$input" | jq -r 'keys[]')

attention=0
registered=()
for name in ${names[@]+"${names[@]}"}; do
  def=$(printf '%s' "$input" | jq -c --arg n "$name" '.[$n]')

  if printf '%s' "$def" | jq -e '[.command?, (.args? // [])[], ((.env? // {}) | .[])]
      | map(strings) | any(test("/Users/|/opt/homebrew|/Applications"))' >/dev/null; then
    echo "    $name: skipped – its command, arguments or env hold a macOS path. Re-add it on the box by hand"
    attention=1
    continue
  fi

  replaced=
  if claude mcp get "$name" >/dev/null 2>&1; then
    if [ -z "$REPLACE" ]; then
      echo "    $name: already registered – left as it is (--replace replaces it)"
      continue
    fi
    if ! claude mcp remove --scope user "$name" >/dev/null 2>&1; then
      echo "    $name: failed – could not remove the existing registration, which is left as it is"
      attention=1
      continue
    fi
    replaced=1
  fi
  if ! printf '%s' "$def" | claude mcp add-json --scope user "$name" - >/dev/null 2>&1; then
    if [ -n "$replaced" ]; then
      echo "    $name: FAILED – the existing registration was removed and the new one was refused, so $name is not registered now"
    else
      echo "    $name: failed – claude mcp add-json refused the definition"
    fi
    attention=1
    continue
  fi
  if [ -n "$replaced" ]; then echo "    $name: replaced"; else echo "    $name: registered"; fi
  registered+=("$name")

  cmd=$(printf '%s' "$def" | jq -r 'if (.type // "stdio") == "stdio" then .command // "" else "" end')
  if [ -n "$cmd" ] && ! command -v "$cmd" >/dev/null; then
    echo "    $name: its command is not on this box's PATH – install it, or the server can't start"
    attention=1
  fi
  mapfile -t vars < <(printf '%s' "$def" | jq -r '[.. | strings] | map(scan("\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}") | .[0]) | unique[]')
  for var in ${vars[@]+"${vars[@]}"}; do
    if [ -z "${!var+set}" ]; then
      echo "    $name: refers to \${$var}, which this box's environment doesn't set"
      attention=1
    fi
  done
done

# The list's raw lines carry each server's URL or command line, so only the
# name and a status that matches a known form are printed.
echo
echo "==> Status"
needs_login=()
while IFS= read -r line; do
  case $line in *": "*" - "*) ;; *) continue ;; esac
  n=${line%%: *}
  s=${line##* - }
  case $s in
    *Connected* | *"Needs authentication"* | *Failed* | *Pending* | *Disabled*) ;;
    *) s="status not recognised" ;;
  esac
  if [[ $n == "claude.ai "* ]] || in_list "$n" ${registered[@]+"${registered[@]}"}; then
    echo "    $n: $s"
    [[ $s != *"Needs authentication"* ]] || needs_login+=("$n")
  fi
done < <(claude mcp list 2>/dev/null || true)

if [ ${#needs_login[@]} -gt 0 ]; then
  echo
  echo "==> Owner's sign-ins, in a terminal on the box as $BOX_USER:"
  for n in "${needs_login[@]}"; do
    if [[ $n == "claude.ai "* ]]; then
      echo "    claude mcp login \"$n\" --no-browser     # open the link it prints on any device"
    else
      echo "    $n: run claude, then /mcp, choose $n and follow the sign-in"
      echo "      (or: claude mcp login \"$n\" --no-browser, which prints a link and asks for the redirect URL back)"
    fi
  done
fi

echo
echo "A server listed as connected is not yet shown to work: use each one once from a session (README, step 8)."
exit "$attention"
