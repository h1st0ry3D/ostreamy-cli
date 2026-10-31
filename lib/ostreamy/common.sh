#!/bin/bash
# Shared helpers for ostreamy. Source this after SELF_DIR is set.
#
# Layout model: STREAM is a persistent headless output that Sunshine captures. It
# is never created/destroyed/enabled/disabled at runtime, because Sunshine resolves
# output_name only at session start and silently falls back to monitors[0] when the
# target is missing -- after which the capture resolution changes under the live
# encoder and the video freezes while input keeps working.
#
# Only the *layout* changes:
#   idle      STREAM parked off to the left (negative x), panel native, focus panel
#   streaming panel mirrors STREAM, workspaces move onto STREAM

set -u

: "${OSTREAMY_CONF:=${XDG_CONFIG_HOME:-$HOME/.config}/ostreamy/config.sh}"
# shellcheck disable=SC1090
[ -f "$OSTREAMY_CONF" ] && . "$OSTREAMY_CONF"

OUTPUT=${OUTPUT:-STREAM}
MODE=${MODE:-1920x1200@60}
GRACE=${GRACE:-30}
QUIET=${QUIET:-20}
COOLDOWN=${COOLDOWN:-70}
INTERVAL=${INTERVAL:-0.25}
PORTS=${PORTS:-47984 47989 48010}
PUMP=${PUMP:-1}                 # seconds to let Hyprland settle between steps
LOG=${SUNSHINE_LOG:-$HOME/.config/sunshine/sunshine.log}

# A Hyprland restart leaves HYPRLAND_INSTANCE_SIGNATURE stale in long-lived shells
# and services; every hyprctl call then fails with a socket error.
resolve_sig() {
  local sig
  sig=$(hyprctl instances -j 2>/dev/null | jq -r 'sort_by(.time) | last | .instance // empty')
  [ -n "$sig" ] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
}

monitors() { hyprctl monitors all -j 2>/dev/null; }

exists() { monitors | jq -e --arg n "$OUTPUT" 'any(.[]; .name == $n)' >/dev/null 2>&1; }

panel_name() {
  monitors | jq -r --arg n "$OUTPUT" '.[] | select(.name != $n and (.disabled|not)) | .name' | head -n 1
}

# hyprland reports refreshRate with decimals (143.96899); a mode rule with that
# precision is silently rejected, so rules must use the integer form.
panel_mode_int() {
  monitors | jq -r --arg n "$1" '.[] | select(.name == $n) | "\(.width)x\(.height)@\(.refreshRate|round)"' | head -n 1
}

# The panel's own best mode: largest available resolution, highest refresh within
# it. Must NOT be derived from the panel's *current* resolution: while the panel
# mirrors STREAM it reports the stream's size (1920x1200), so "restore the current
# resolution" would restore the Deck resolution instead of the monitor's native one.
panel_best_mode() {
  local name
  name="$1"
  monitors | jq -r --arg n "$name" '
    ([.[] | select(.name == $n)][0]) as $m
    | ($m.availableModes // [])
    | map(select(test("^[0-9]+x[0-9]+@[0-9.]+Hz$")))
    | map(. as $s
          | { s: $s,
              w: ($s | split("x")[0] | tonumber),
              h: ($s | split("x")[1] | split("@")[0] | tonumber),
              r: ($s | split("@")[1] | sub("Hz$"; "") | tonumber) })
    | if length == 0 then "\($m.width)x\($m.height)@\($m.refreshRate|round)"
      else
        (map(.w * .h) | max) as $area
        | map(select(.w * .h == $area))
        | sort_by(.r) | last
        | "\(.w)x\(.h)@\(.r|round)"
      end' | head -n 1
}

panel_scale() {
  monitors | jq -r --arg n "$1" '.[] | select(.name == $n) | "\(.scale)"' | head -n 1
}
stream_width() {
  monitors | jq -r --arg n "$OUTPUT" '.[] | select(.name == $n) | .width' | head -n 1
}

# Park STREAM immediately to the left of the origin: never overlaps the panel, and
# the panel's own "auto" placement then lands at 0,0 without editing its rule.
park_position() {
  local w
  w=$(stream_width); [ -n "$w" ] || w=1920
  printf -- '-%sx0' "$w"
}

# STREAM must exist with a stable mode. Create it if missing and pin the mode.
ensure_output() {
  local park
  if ! exists; then
    hyprctl output create headless "$OUTPUT" >/dev/null 2>&1 || return 1
    hyprctl eval "hl.monitor({ output = \"$OUTPUT\", mode = \"$MODE\", position = \"$(park_position)\" })" >/dev/null 2>&1 || true
    hyprctl eval "hl.monitor({ output = \"$OUTPUT\", mode = \"$MODE\", position = \"$(park_position)\" })" >/dev/null 2>&1 || true
    return 2   # created
  fi
  park=$(park_position)
  hyprctl eval "hl.monitor({ output = \"$OUTPUT\", mode = \"$MODE\", position = \"$park\" })" >/dev/null 2>&1 || true
  return 0
}

# Workspace ids are numbers. A quoted id is silently rejected by the dispatcher and
# the window is then stranded on a removed output (mon=-1).
move_workspaces() {
  local from="$1" to="$2" ws
  [ -n "$to" ] || return 0
  for ws in $(hyprctl workspaces -j 2>/dev/null |
                jq -r --arg m "$from" '.[] | select(.monitor == $m) | .id'); do
    hyprctl dispatch "hl.dsp.workspace.move({ workspace = $ws, monitor = \"$to\" })" >/dev/null 2>&1 || true
  done
}

rescue_orphans() {
  local to="$1" ws
  [ -n "$to" ] || return 0
  for ws in $(hyprctl workspaces -j 2>/dev/null | jq -r '.[] | select(.monitor == "?") | .id'); do
    hyprctl dispatch "hl.dsp.workspace.move({ workspace = $ws, monitor = \"$to\" })" >/dev/null 2>&1 || true
  done
}

# $1 = mirror | plain. A rule for the panel is built from its own current mode and
# scale, so no connector or EDID string is hardcoded.
apply_panel_rule() {
  local name mode scale
  name=$(panel_name); [ -n "$name" ] || return 0
  mode=$(panel_mode_int "$name"); scale=$(panel_scale "$name")
  [ -n "$mode" ] || mode="preferred"
  [ -n "$scale" ] || scale=1
  if [ "$1" = "mirror" ]; then
    hyprctl eval "hl.monitor({ output = \"$name\", mode = \"$mode\", position = \"auto\", scale = $scale, mirror = \"$OUTPUT\" })" >/dev/null 2>&1 || true
  else
    mode=$(panel_best_mode "$name")
    hyprctl eval "hl.monitor({ output = \"$name\", mode = \"$mode\", position = \"0x0\", scale = $scale })" >/dev/null 2>&1 || true
  fi
}

focus_a_windowed_workspace() {
  local name ws
  name=$(panel_name); [ -n "$name" ] || return 0
  ws=$(hyprctl workspaces -j 2>/dev/null |
         jq -r --arg m "$name" '[.[] | select(.monitor == $m and .windows > 0)] | sort_by(-.windows) | .[0].id // empty')
  [ -n "$ws" ] || return 0
  hyprctl dispatch "hl.dsp.focus({ workspace = $ws })" >/dev/null 2>&1 || true
}

mirror_active() {
  local id
  id=$(monitors | jq -r --arg n "$OUTPUT" '.[] | select(.name == $n) | .id' | head -n 1)
  [ -n "$id" ] || return 1
  monitors | jq -e --arg id "$id" --arg n "$OUTPUT" '.[] | select(.name != $n and .mirrorOf == $id)' >/dev/null 2>&1
}

SEEN_FILE=${OSTREAMY_SEEN_FILE:-${XDG_RUNTIME_DIR:-/tmp}/ostreamy-seen}

port_filter() {
  local p expr=""
  for p in $PORTS; do expr="${expr}${expr:+|}(:$p)([^0-9]|$)"; done
  printf '%s' "$expr"
}

client_connections() {
  ss -Htan 2>/dev/null | grep -E "$(port_filter)" | grep -vE 'LISTEN|127\.0\.0\.1|\[::1\]' | wc -l
}

# Identify the *client* end. For an inbound connection the peer is the client; for a
# local test connection the peer is our own listening port, so the local endpoint is
# the client side instead. Normalising both keeps novelty detection honest.
client_endpoints() {
  ss -Htan 2>/dev/null | grep -E "$(port_filter)" |
    grep -vE 'LISTEN|127\.0\.0\.1|\[::1\]' |
    awk -v ports="$PORTS" '
      BEGIN { n = split(ports, p, " "); for (i = 1; i <= n; i++) wanted[p[i]] = 1 }
      {
        local = $4; peer = $5
        split(peer, pp, ":"); peerport = pp[length(pp)]
        if (peerport in wanted) print local; else print peer
      }' | sort -u
}

# A brand-new client raises the endpoint set; TIME-WAIT leftovers from a closed one
# do not, which is what makes a manual `off` stick.
new_endpoints() {
  local current
  current=$(client_endpoints)
  [ -n "$current" ] || return 1
  [ -f "$SEEN_FILE" ] || { printf '%s\n' "$current" > "$SEEN_FILE"; return 1; }
  comm -13 <(sort "$SEEN_FILE") <(printf '%s\n' "$current") | grep -q . || return 1
}

remember_endpoints() { client_endpoints > "$SEEN_FILE" 2>/dev/null || true; }

# Sunshine's own log is the only reliable "session ended"/"session started" signal.
log_size() { stat -c %s "$LOG" 2>/dev/null || echo 0; }

log_since() {
  local offset="$1" pattern="$2" size
  [ -f "$LOG" ] || return 1
  size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  [ "$size" -lt "$offset" ] && offset=0
  [ "$size" -le "$offset" ] && return 1
  tail -c +$((offset + 1)) "$LOG" 2>/dev/null | grep -qE "$pattern"
}

# A live session, as opposed to TIME-WAIT left behind by a closed control
# connection.
live_connections() {
  ss -Htan 2>/dev/null | grep -E 'ESTAB|CLOSE-WAIT|SYN-SENT|SYN-RECV' |
    grep -E "$(port_filter)" | grep -vE '127\.0\.0\.1|\[::1\]' | wc -l
}
