#!/usr/bin/env bash
# Step 4 – re-add the MCP servers at user scope. Runs as the box user.
#
# This is my server set, kept as a worked example – replace it with yours. The
# part worth copying whatever your set is: s(), which tests the VALUE a secret
# read returns, because `op read` exits 0 on an empty field.
#
# Every secret is read from 1Password at run time. No values live in this repo.
# Needs: OP_SERVICE_ACCOUNT_TOKEN exported, `op` CLI installed, vault `cloud-box`
# populated (see the README).
#
# Not handled here, by design:
#   claude.ai BigQuery + Google Drive – account-level connectors, they follow the
#     Anthropic login rather than the machine. Nothing to re-add.
#   mixpanel-eu – project-scoped in fidero-os/.mcp.json, arrives with the clone.
#   Claude in Chrome – stays laptop-only.
set -euo pipefail

: "${OP_SERVICE_ACCOUNT_TOKEN:?export OP_SERVICE_ACCOUNT_TOKEN first}"
V=op://cloud-box

# Read a secret by item name. API Credential items expose a "credential" field
# that is empty when the value was stored under "api-key" instead, and `op read`
# exits 0 on an empty field, so test the VALUE not the exit code.
s() {
  local item="$1" field="${2:-}" v=""
  if [ -n "$field" ]; then
    v=$(op read "$V/$item/$field" 2>/dev/null || true)
  else
    v=$(op read "$V/$item/credential" 2>/dev/null || true)
    [ -n "$v" ] || v=$(op read "$V/$item/api-key" 2>/dev/null || true)
  fi
  [ -n "$v" ] || { echo "!! no non-empty credential or api-key on $V/$item" >&2; return 1; }
  printf '%s' "$v"
}

echo "==> Remote OAuth / token servers"

claude mcp add --scope user --transport http linear https://mcp.linear.app/mcp
# Prints an auth URL when headless – open it on the laptop, paste the redirect back.

claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp \
  --header "CONTEXT7_API_KEY: $(s context7)"

claude mcp add --scope user --transport http stitch https://stitch.googleapis.com/mcp \
  --header "X-Goog-Api-Key: $(s stitch)"

# Typefully takes its key as a URL query parameter. On the laptop this sits in
# ~/.claude.json in the clear; rotate during the move and keep it in 1Password.
claude mcp add --scope user --transport http typefully \
  "https://mcp.typefully.com/mcp?TYPEFULLY_API_KEY=$(s typefully)"

echo "==> Slack – community stdio server per workspace"
# Anthropic's official Slack connector is one workspace per Claude account, and
# Claude Code cannot complete its OAuth (it needs dynamic client registration,
# which that auth server does not support). The community stdio server takes an
# xoxp token per workspace and does not collide, so both go through it.
mkdir -p "$HOME/.slack-mcp"
for ws in fidero drivn; do
  claude mcp add --scope user "slack-$ws" \
    --env "SLACK_MCP_XOXP_TOKEN=$(s "slack-$ws" xoxp-token)" \
    --env "SLACK_MCP_ADD_MESSAGE_TOOL=true" \
    --env "SLACK_MCP_CHANNELS_CACHE=$HOME/.slack-mcp/$ws-channels.json" \
    --env "SLACK_MCP_USERS_CACHE=$HOME/.slack-mcp/$ws-users.json" \
    -- npx -y slack-mcp-server@latest --transport stdio
done

echo "==> Stdio servers"

claude mcp add --scope user firecrawl \
  --env "FIRECRAWL_API_KEY=$(s firecrawl)" \
  -- npx -y firecrawl-mcp

claude mcp add --scope user buttondown \
  --env "BUTTONDOWN_API_KEY=$(s buttondown)" \
  -- npx -y buttondown-mcp

# Paths match the laptop's layout so the restored token files land where the
# servers already expect them.
for acct in fidero drivn; do
  claude mcp add --scope user "gmail-$acct" \
    --env "GMAIL_OAUTH_PATH=$HOME/.gmail-mcp-$acct/gcp-oauth.keys.json" \
    --env "GMAIL_CREDENTIALS_PATH=$HOME/.gmail-mcp-$acct/credentials.json" \
    -- npx -y @gongrzhe/server-gmail-autoauth-mcp
done

# Calendar reuses gmail-fidero's OAuth client, as on the laptop.
claude mcp add --scope user gcal-fidero \
  --env "GOOGLE_OAUTH_CREDENTIALS=$HOME/.gmail-mcp-fidero/gcp-oauth.keys.json" \
  -- npx -y @cocal/google-calendar-mcp

claude mcp add --scope user whatsapp \
  -- "$HOME/.local/bin/uv" --directory "$HOME/whatsapp-mcp/whatsapp-mcp-server" run main.py

claude mcp add --scope user hookdeck -- hookdeck gateway mcp

echo "==> Playwright – replaces Claude in Chrome on the box"
npm i -g @playwright/mcp
npx playwright install --with-deps chromium
# --browser chromium matters: the server defaults to the "chrome" channel and
# looks for Google Chrome at /opt/google/chrome, which is not what we installed.
# --output-dir keeps traces and screenshots out of whatever repo it runs from,
# where they otherwise show up as an untracked .playwright-mcp/ directory.
claude mcp add --scope user playwright \
  -- npx @playwright/mcp@latest --browser chromium \
     --user-data-dir "$HOME/.local/share/playwright-profile" \
     --output-dir "$HOME/.local/share/playwright-mcp-output"

echo "==> WhatsApp bridge service"
# The bridge is built and paired separately (see the runbook) – pairing needs a
# QR scan and cannot be scripted. This just writes the unit so a paired bridge
# comes back after a reboot.
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/whatsapp-bridge.service" <<'UNIT'
[Unit]
Description=WhatsApp bridge for the WhatsApp MCP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/whatsapp-mcp/whatsapp-bridge
ExecStart=%h/whatsapp-mcp/whatsapp-bridge/whatsapp-bridge
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload

echo
echo "==> Restoring OAuth token files from 1Password"
# Authed on the laptop, stored as 1Password documents, restored to the same paths.
restore() { mkdir -p "$(dirname "$2")"; op document get "$1" --out-file "$2"; chmod 600 "$2"; }
restore "gmail-fidero-oauth" "$HOME/.gmail-mcp-fidero/gcp-oauth.keys.json"
restore "gmail-fidero-creds" "$HOME/.gmail-mcp-fidero/credentials.json"
restore "gmail-drivn-oauth"  "$HOME/.gmail-mcp-drivn/gcp-oauth.keys.json"
restore "gmail-drivn-creds"  "$HOME/.gmail-mcp-drivn/credentials.json"
# The calendar server keeps its own token separate from the OAuth client.
restore "gcal-fidero-tokens" "$HOME/.config/google-calendar-mcp/tokens.json"

echo
echo "==> Health check"
claude mcp list

cat <<'MSG'

Still needs you:
  - Linear and the official Slack server: open the printed URL, paste the redirect
  - WhatsApp: build the bridge (github.com/lharries/whatsapp-mcp), run it under systemd,
    scan the QR in the terminal, then store the session file in 1Password

Register Playwright in the other two CLIs as well (Codex and Gemini configs).
MSG
