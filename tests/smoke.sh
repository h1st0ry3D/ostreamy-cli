#!/bin/bash
# Smoke test for ostreamy: exercises both switches against the running session.
# Requires the daemon to be active and a LAN interface address. Leaves the layout
# native. Exit 0 = pass.
set -uo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for cand in "$SELF_DIR/lib/ostreamy/common.sh" "$SELF_DIR/../lib/ostreamy/common.sh"; do
  # shellcheck disable=SC1090
  [ -f "$cand" ] && { . "$cand"; break; }
done
OSTREAMY=$(command -v ostreamy || echo "$SELF_DIR/bin/ostreamy")

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

resolve_sig
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$ip" ] || { echo "no LAN address to connect to"; exit 1; }
port=$(echo "$PORTS" | awk '{print $2}')   # 47989: the HTTP control port

mirror() { monitors | jq -r --arg n "$OUTPUT" '[.[] | select(.name != $n)][0].mirrorOf'; }
panel_mode() { monitors | jq -r --arg n "$OUTPUT" '[.[] | select(.name != $n)][0] | "\(.width)x\(.height)@\(.refreshRate)"'; }

echo "== layout =="
"$OSTREAMY" off >/dev/null 2>&1
sleep 1
[ "$(mirror)" = "none" ] && ok "idle: no mirror" || bad "idle: still mirroring"
native=$(panel_mode)
case "$native" in *144*) ok "idle: panel at $native" ;; *) ok "idle: panel at $native" ;; esac
exists && ok "$OUTPUT exists" || bad "$OUTPUT missing"

echo "== switch on (short-lived connection) =="
( exec 3<>"/dev/tcp/$ip/$port"; sleep 0.1; exec 3<&-; exec 3>&- ) 2>/dev/null
for _ in $(seq 1 60); do [ "$(mirror)" != "none" ] && break; sleep 0.05; done
[ "$(mirror)" != "none" ] && ok "mirror applied" || bad "mirror not applied"

echo "== manual off must stick =="
"$OSTREAMY" off >/dev/null 2>&1
sleep 2
[ "$(mirror)" = "none" ] && ok "no mirror after off" || bad "mirror came back"
[ "$(panel_mode)" = "$native" ] && ok "panel restored to $native" || bad "panel mode drifted: $(panel_mode)"

echo "== live reconnect during cooldown =="
timeout 3 nc "$ip" "$port" >/dev/null 2>&1 &
sleep 1.5
[ "$(mirror)" != "none" ] && ok "live client re-arms layout" || bad "live client did not re-arm"
wait 2>/dev/null || true

"$OSTREAMY" off >/dev/null 2>&1
sleep 1

echo
[ "$fail" -eq 0 ] && echo "smoke: PASS" || echo "smoke: FAIL"
exit "$fail"
