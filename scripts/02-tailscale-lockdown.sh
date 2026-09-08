#!/usr/bin/env bash
# Step 2 – Tailscale, then close public SSH. Runs as root on the box.
# Provider note: written for a host with no cloud firewall in front of it, so
# ufw is the whole firewall. If yours has one, mirror the rules there too.
#
# Two phases on purpose. Phase 1 brings Tailscale up and stops. You then prove
# SSH works over the tailnet FROM ANOTHER DEVICE. Only then run phase 2, which
# is the step that can lock you out.
#
#   ./02-tailscale-lockdown.sh up      # phase 1
#   ./02-tailscale-lockdown.sh close   # phase 2 – after you have tested the tailnet
set -euo pipefail

BOX_USER="${BOX_USER:-dan}"

phase_up() {
  if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  tailscale up --ssh
  echo
  tailscale status
  TS_IP=$(tailscale ip -4)
  TS_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
  echo
  echo "Tailscale address: $TS_IP"
  echo "MagicDNS name:     $TS_NAME"
  cat <<MSG

Before running 'close', do all of these:
  1. Approve this machine in the Tailscale admin console, MagicDNS on
  2. From the laptop:  ssh $BOX_USER@$TS_NAME
  3. Keep that session open while you run 'close', as a way back in

MSG
}

phase_close() {
  command -v tailscale >/dev/null || { echo "Tailscale not installed – run 'up' first" >&2; exit 1; }
  TS_IP=$(tailscale ip -4)
  [ -n "$TS_IP" ] || { echo "No Tailscale IPv4 – refusing to close public SSH" >&2; exit 1; }

  read -rp "Confirmed SSH over the tailnet works from another device? [yes/NO] " ok
  [ "$ok" = "yes" ] || { echo "Aborting."; exit 1; }

  # Dead-man switch. Everything below is undone in REVERT_AFTER seconds unless
  # the script reaches the end and cancels it. A wrong rule then locks you out
  # for five minutes instead of until you can reach the web console.
  REVERT_AFTER="${REVERT_AFTER:-300}"
  nohup bash -c "sleep $REVERT_AFTER
    rm -f /etc/ssh/sshd_config.d/99-tailscale.conf
    systemctl restart ssh
    ufw --force disable" >/dev/null 2>&1 &
  REVERT_PID=$!
  echo "==> Auto-revert armed for ${REVERT_AFTER}s (pid $REVERT_PID)"

  echo "==> Binding sshd to $TS_IP only"
  cat > /etc/ssh/sshd_config.d/99-tailscale.conf <<CONF
ListenAddress $TS_IP
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers $BOX_USER
CONF
  sshd -t
  systemctl restart ssh

  echo "==> Host firewall: allow only Tailscale"
  # UDP 41641 lets Tailscale hole-punch a direct path instead of relaying.
  # mosh's UDP 60000-61000 only ever travels inside the tunnel, so it needs no rule.
  apt install -y ufw
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on tailscale0
  ufw allow 41641/udp comment 'tailscale direct'
  ufw --force enable
  ufw status verbose

  echo
  echo "==> Open a NEW terminal on the laptop and confirm this still works:"
  echo "     ssh $BOX_USER@$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')"
  echo
  read -rp "Did that new connection succeed? [yes/NO] " ok2
  if [ "$ok2" = "yes" ]; then
    kill "$REVERT_PID" 2>/dev/null && echo "==> Auto-revert cancelled. Lockdown is permanent."
  else
    echo "==> Leaving auto-revert armed – it will undo this in under ${REVERT_AFTER}s."
    exit 1
  fi

  cat <<MSG

Public SSH is closed. Netcup has no cloud firewall in front of the box, so ufw
above is the whole firewall – there is no second layer to configure, and none to
fall back on if these rules are wrong.

Way back in if the tailnet breaks: the Netcup control panel's remote console.
MSG
}

case "${1:-}" in
  up)    phase_up ;;
  close) phase_close ;;
  *)     echo "usage: $0 up|close" >&2; exit 1 ;;
esac
