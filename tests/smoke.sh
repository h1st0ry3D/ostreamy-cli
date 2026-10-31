#!/bin/bash
# Smoke test for Ostreamy: exercises the watcher with signals it can rely on.
# Requires the daemon to be active. Leaves the layout native. Exit 0 = pass.
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

for c in hyprctl jq ss; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing dependency: $c"; exit 1; }
done
resolve_sig
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$ip" ] || { echo "no LAN address to connect to"; exit 1; }
port=$(echo "$PORTS" | awk '{print $2}')   # 47989, the HTTP control port

mirror()  { monitors | jq -r --arg n "$OUTPUT" '[.[] | select(.name != $n)][0].mirrorOf'; }
panel()   { monitors | jq -r --arg n "$OUTPUT" '[.[] | select(.name != $n)][0] | "\(.width)x\(.height)@\(.refreshRate)"'; }
settle()  { sleep 6; }

# Held connection, emulating an active session. No netcat required.
hold_start() {
  if command -v nc >/dev/null 2>&1; then
    timeout 6 nc "$ip" "$port" >/dev/null 2>&1 &
  else
    timeout 6 bash -c "exec 3<>/dev/tcp/$ip/$port; sleep 6" >/dev/null 2>&1 &
  fi
}

printf '%s\n' '== idle =='
"$OSTREAMY" off >/dev/null 2>&1
settle
[ "$(mirror)" = "none" ] && ok "no mirror" || bad "still mirroring"
native=$(panel)
ok "panel $native"
exists && ok "$OUTPUT exists" || bad "$OUTPUT missing"

printf '%s\n' '== live client arms =='
hold_start; sleep 1.5
[ "$(mirror)" != "none" ] && ok "armed by a live connection" || bad "live connection did not arm"
wait $! 2>/dev/null || true

printf '%s\n' '== session end restores the desktop =='
printf '[%s]: Info: CLIENT DISCONNECTED\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" >> "$LOG"
sleep 1.5
[ "$(mirror)" = "none" ] && ok "no mirror after disconnect" || bad "mirror survived the disconnect"
[ "$(panel)" = "$native" ] && ok "panel restored to $native" || bad "panel drifted to $(panel)"

printf '%s\n' '== menu polling does not re-arm =='
( exec 3<>"/dev/tcp/$ip/$port"; exec 3<&-; exec 3>&- ) 2>/dev/null
sleep 1.5
[ "$(mirror)" = "none" ] && ok "short poll ignored" || bad "short poll re-armed the layout"

printf '%s\n' '== a real session still arms during the quiet window =='
hold_start; sleep 1.5
[ "$(mirror)" != "none" ] && ok "live connection bypasses the quiet window" || bad "quiet window blocked a live client"
wait $! 2>/dev/null || true

"$OSTREAMY" off >/dev/null 2>&1
settle

echo
[ "$fail" -eq 0 ] && echo "smoke: PASS" || echo "smoke: FAIL"
exit "$fail"
