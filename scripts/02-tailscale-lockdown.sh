#!/usr/bin/env bash
# Step 2 – Tailscale, then close public SSH. Runs as root on the box.
# Provider note: written for a host with no cloud firewall in front of it, so
# ufw is the whole firewall. If yours has one, mirror the rules there too.
#
# Two phases on purpose. Phase 1 brings Tailscale up and stops. The owner then
# proves SSH works over the tailnet FROM THEIR LAPTOP. Only then run phase 2,
# which is the step that can lock you out.
#
#   ./02-tailscale-lockdown.sh up      # phase 1
#   ./02-tailscale-lockdown.sh close   # phase 2 – after the tailnet is proved
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
read_inputs
require_root

DROPIN="$SSHD_CONFIG_D/99-tailscale.conf"
# Whichever of the confirmation and the revert creates this first wins, and the
# other stands down, so a late "yes" can't report a close the revert undid.
DECIDED="$CLOUD_BOX_RUN_DIR/decided"

phase_up() {
  if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  echo "==> Owner: open the URL Tailscale prints next and sign in to your Tailscale account"
  tailscale up --ssh
  echo
  tailscale status
  TS_IP=$(tailscale ip -4)
  TS_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
  echo
  echo "Tailscale address: $TS_IP"
  echo "MagicDNS name:     $TS_NAME"
  cat <<MSG

Owner's steps, now:
  1. If your tailnet asks for new devices to be approved, approve this one in
     the Tailscale admin console
  2. Install Tailscale on your laptop and sign in to the same account
  3. From the laptop, connect once:  ssh $BOX_USER@$TS_NAME
  4. Sign in as root in the provider's web console (the README says where the
     root password comes from)

Then 'close' – straight away if you are building your own box, or as the last
configuration step if you are building it for someone else (see the README).

MSG
}

phase_close() {
  # Before anything else, and held until this script exits, so a second close
  # or a handover can't start while this one runs or its revert is armed.
  take_close_lock "a close is running, or the revert from an earlier one is still armed. Wait for it to finish (public SSH is then open again), then run 'close' again."
  rm -rf "$DECIDED"

  command -v tailscale >/dev/null || { echo "Tailscale not installed – run 'up' first" >&2; exit 1; }
  TS_IP=$(tailscale ip -4)
  [ -n "$TS_IP" ] || { echo "No Tailscale IPv4 – refusing to close public SSH" >&2; exit 1; }
  TS_NAME=$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')
  # Installed by 01-base.sh, so nothing below waits on apt inside the revert window.
  command -v ufw >/dev/null || die "ufw is not installed – run 01-base.sh first"

  read -rp "Confirmed SSH over the tailnet works from the owner's laptop? [yes/NO] " ok
  [ "$ok" = "yes" ] || { echo "Aborting."; exit 1; }

  # Dead-man switch. Everything below is undone in REVERT_AFTER seconds unless
  # the script reaches the end and cancels it. A wrong rule then locks you out
  # for five minutes instead of until you can reach the web console.
  #
  # The revert is always the last to change anything: when it fires it stops
  # this script and everything it started, then undoes the close, and reports
  # the result here (revert_close in lib.sh).
  REVERT_AFTER="${REVERT_AFTER:-300}"
  rm -f "$CLOSED_MARKER"
  # shellcheck disable=SC2016 # the job's $1.. are the arguments after the script
  nohup setsid bash -c '. "$1"; shift; revert_close "$@"' _ "$CLOUD_BOX_LIB" \
    "$REVERT_AFTER" "$DECIDED" "$DROPIN" "$CLOSED_MARKER" "$$" >/dev/null 2>&1 &
  REVERT_PID=$!
  echo "==> Auto-revert armed for ${REVERT_AFTER}s (pid $REVERT_PID)"

  echo "==> Binding sshd to $TS_IP only"
  # These settings govern sshd alone. Tailscale SSH is a separate listener that
  # never reads them: its control is the tailnet's SSH policy.
  cat > "$DROPIN" <<CONF
ListenAddress $TS_IP
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers $BOX_USER
CONF
  sshd -t
  systemctl restart ssh

  echo "==> Host firewall: allow only Tailscale"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on tailscale0
  ufw --force enable
  ufw status verbose

  echo
  echo "==> From the owner's laptop, open a NEW connection and confirm it works:"
  echo "     ssh $BOX_USER@$TS_NAME"
  echo
  read -rp "Did that new connection succeed? [yes/NO] " ok2
  if [ "$ok2" != "yes" ]; then
    echo "==> Leaving auto-revert armed – it will undo this in under ${REVERT_AFTER}s."
    exit 1
  fi
  if ! mkdir "$DECIDED" 2>/dev/null; then
    echo "!! Too late: ${REVERT_AFTER}s ran out before that answer, and the revert is" >&2
    echo "!! undoing the close. Public SSH is open again once it reports." >&2
    echo "!! Run 'close' again." >&2
    exit 1
  fi
  kill "$REVERT_PID" 2>/dev/null || true
  wait "$REVERT_PID" 2>/dev/null || true
  mkdir -p "$CLOUD_BOX_STATE_DIR"
  touch "$CLOSED_MARKER"
  echo "==> Auto-revert cancelled. Lockdown is permanent."

  cat <<MSG

Public SSH is closed. Netcup has no cloud firewall in front of the box, so ufw
above is the whole firewall – there is no second layer to configure, and none to
fall back on if these rules are wrong. Tailscale adds firewall chains of its own
beside ufw's, which 06-handover.sh prints in full.

Way back in if the tailnet breaks: the Netcup control panel's remote console.
MSG
}

case "${1:-}" in
  up)    phase_up ;;
  close) phase_close ;;
  *)     echo "usage: $0 up|close" >&2; exit 1 ;;
esac
