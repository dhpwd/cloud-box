#!/usr/bin/env bash
# Step 10 – handover. Removes the operator's key from root and the box user and
# prints the box's final state. Runs as root, in the root session that ran the
# close. Only for an operator building a box for someone else: an owner
# building their own box skips it.
#
# It sets up nothing for later access, and leaves a marker that stops
# 01-base.sh adding the operator's key again.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
read_inputs
require_root

# An unconfirmed close leaves the same drop-in and an active ufw as a confirmed
# one, until its revert reopens public SSH. Only the marker and a free lock
# show the close was confirmed and nothing is left to undo it.
take_close_lock "a revert from '02-tailscale-lockdown.sh close' is still armed. Let it run, then run the close again and confirm it, then run this."
[ -e "$CLOSED_MARKER" ] || die "the close has not been confirmed. Run '02-tailscale-lockdown.sh close' and confirm it first."

require_sshd_key_only root "$BOX_USER"
[ "$(sshd_setting root permitrootlogin)" = no ] ||
  die "sshd still allows a root login. The first file that sets PermitRootLogin is $(sshd_first_setter permitrootlogin)"

mkdir -p "$CLOUD_BOX_STATE_DIR"
touch "$HANDED_OVER_MARKER"

echo "==> Removing the operator's key"
revoke_operator_key

echo
echo "==> Final state"
echo "--- Remote Control servers"
systemctl --user -M "$BOX_USER@" list-units 'claude-rc@*' --all --no-pager --plain || true
echo "--- Tailscale name"
tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//'
echo "--- sshd"
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|listenaddress|allowusers) '
echo "--- ufw"
ufw status verbose
# ufw status shows only ufw's own rules. Tailscale adds chains of its own.
echo "--- every firewall rule, IPv4 and IPv6"
if command -v nft >/dev/null; then
  nft list ruleset
else
  iptables -S
  ip6tables -S
fi

cat <<MSG

Handover done.
  Operator: close every session you have open on this box now.
  Owner: from your phone, open a session in one repo and ask it something
  short. That shows the box works as delivered.
MSG
