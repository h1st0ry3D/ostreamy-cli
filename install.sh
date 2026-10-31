#!/bin/bash
# Install ostreamy: a stream-ready Hyprland layout for Sunshine + Moonlight.
# Idempotent: safe to re-run after Hyprland/Sunshine updates.
#
#   ./install.sh                 install scripts, unit, config, Hyprland snippet
#   ./install.sh --no-hypr       skip editing ~/.config/hypr/monitors.lua
#   ./install.sh --no-sunshine   skip touching sunshine.conf
#   ./install.sh --encoder auto  nvenc|vaapi|software (default: auto-detect)

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ostreamy"
CONF="$CONF_DIR/config.sh"
HYPR_CONF="$HOME/.config/hypr/monitors.lua"
SUNSHINE_CONF="$HOME/.config/sunshine/sunshine.conf"
MARK_BEGIN="# >>> ostreamy >>>"
MARK_END="# <<< ostreamy <<<"

do_hypr=1
do_sunshine=1
encoder=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --no-hypr)     do_hypr=0 ;;
    --no-sunshine) do_sunshine=0 ;;
    --encoder)     shift; encoder=${1:-auto} ;;
    -h|--help)     sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%-6s %s\n' "$1" "$2"; }

say INFO "repository: $REPO"

# --- dependencies -----------------------------------------------------------
for c in hyprctl jq ss systemctl; do
  command -v "$c" >/dev/null 2>&1 || { say FAIL "missing dependency: $c"; exit 1; }
done
say OK "core dependencies present"

if ! command -v sunshine >/dev/null 2>&1; then
  say WARN "sunshine is not installed (pacman -S sunshine)"
fi

# --- config -----------------------------------------------------------------
mkdir -p "$CONF_DIR"
if [ -f "$CONF" ]; then
  say OK "config exists: $CONF"
else
  cp "$REPO/config/ostreamy.conf.example" "$CONF"
  # Default stream mode follows the client panel if one looks 16:10-ish, else 1200p.
  say SET "wrote $CONF (edit MODE/OUTPUT there)"
fi

# --- scripts ----------------------------------------------------------------
mkdir -p "$BIN_DIR"
for f in ostreamy ostreamy-watch ostreamy-verify; do
  install -m 0755 "$REPO/bin/$f" "$BIN_DIR/$f"
  say SET "$BIN_DIR/$f"
done
install -d "$HOME/.local/lib/ostreamy"
install -m 0644 "$REPO/lib/ostreamy/common.sh" "$HOME/.local/lib/ostreamy/common.sh"
say SET "$HOME/.local/lib/ostreamy/common.sh"

# --- systemd unit -----------------------------------------------------------
mkdir -p "$UNIT_DIR"
sed "s|@HOME@|$HOME|g" "$REPO/systemd/ostreamy-watch.service" > "$UNIT_DIR/ostreamy-watch.service"
systemctl --user daemon-reload
systemctl --user enable --now ostreamy-watch.service
say SET "ostreamy-watch.service enabled and started"

# Retire the pre-rename unit if this machine still runs it.
if [ -f "$UNIT_DIR/sunshine-stream-watch.service" ]; then
  systemctl --user disable --now sunshine-stream-watch.service >/dev/null 2>&1 || true
  say INFO "disabled legacy sunshine-stream-watch.service"
fi
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" != "yes" ]; then
  say WARN "linger is off: run 'loginctl enable-linger $USER' for pre-login startup"
fi

# --- Hyprland snippet -------------------------------------------------------
if [ "$do_hypr" -eq 1 ]; then
  if [ -f "$HYPR_CONF" ] && grep -qF "$MARK_BEGIN" "$HYPR_CONF"; then
    say OK "hyprland snippet already present in $HYPR_CONF"
  elif [ -f "$HYPR_CONF" ]; then
    cp "$HYPR_CONF" "$HYPR_CONF.bak.$(date +%s)"
    # shellcheck disable=SC1090
    . "$CONF"
    mode="${MODE:-1920x1200@60}"
    width="${mode%%x*}"
    pos="-${width}x0"
    {
      printf '\n%s\n' "$MARK_BEGIN"
      # The template already has "--" comments; code lines must stay live.
      sed -e "s|__MODE__|$mode|g" -e "s|__POS__|$pos|g" \
          -e "s|__OUTPUT__|${OUTPUT:-STREAM}|g" "$REPO/hypr/ostreamy.lua"
      printf '%s\n' "$MARK_END"
    } >> "$HYPR_CONF"
    say SET "appended snippet to $HYPR_CONF (backup kept)"
  else
    say WARN "$HYPR_CONF not found: add hypr/ostreamy.lua manually"
  fi
else
  say INFO "skipped Hyprland config (--no-hypr)"
fi

# --- sunshine.conf ----------------------------------------------------------
if [ "$do_sunshine" -eq 1 ]; then
  mkdir -p "$(dirname "$SUNSHINE_CONF")"
  touch "$SUNSHINE_CONF"
  case "$encoder" in
    auto)
      if command -v nvidia-smi >/dev/null 2>&1; then encoder=nvenc
      elif [ -d /dev/dri ]; then encoder=vaapi
      else encoder=software; fi ;;
  esac
  if grep -qF "$MARK_BEGIN" "$SUNSHINE_CONF"; then
    say OK "sunshine snippet already present"
  else
    cp "$SUNSHINE_CONF" "$SUNSHINE_CONF.bak.$(date +%s)" 2>/dev/null || true
    {
      printf '\n%s\n' "$MARK_BEGIN"
      printf 'output_name = STREAM\n'
      printf 'encoder = %s\n' "$encoder"
      printf '# AV1 must stay unadvertised: Steam Deck has no AV1 hardware decoder.\n'
      grep -q '^av1_mode' "$SUNSHINE_CONF" || printf 'av1_mode = 1\n'
      printf '%s\n' "$MARK_END"
    } >> "$SUNSHINE_CONF"
    say SET "sunshine.conf: output_name=STREAM, encoder=$encoder"
  fi
  systemctl --user restart sunshine >/dev/null 2>&1 || say WARN "could not restart sunshine"
fi

# --- firewall ---------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  rules=$(sudo -n ufw status 2>/dev/null || true)
  if [ -z "$rules" ]; then
    say INFO "check the firewall yourself: sudo ufw status"
  elif grep -q '47984' <<<"$rules" && grep -q '47998:48002' <<<"$rules"; then
    say OK "ufw already allows Sunshine ports"
  else
    cat <<'EOF'
INFO   add these (root), LAN-scoped for safety:
         sudo ufw allow from 192.168.0.0/16 to any port 47984 proto tcp comment 'sunshine https'
         sudo ufw allow from 192.168.0.0/16 to any port 47989 proto tcp comment 'sunshine http'
         sudo ufw allow from 192.168.0.0/16 to any port 48010 proto tcp comment 'sunshine rtsp'
         sudo ufw allow from 192.168.0.0/16 to any port 47998:48002 proto udp comment 'sunshine stream'
EOF
  fi
fi

# --- apply ------------------------------------------------------------------
"$BIN_DIR/ostreamy" ensure >/dev/null 2>&1 || true
hyprctl reload >/dev/null 2>&1 || true
"$BIN_DIR/ostreamy" off >/dev/null 2>&1 || true

echo
say OK "installed. Verify with:"
echo "         $BIN_DIR/ostreamy-verify"
echo "         $BIN_DIR/ostreamy-verify --simulate-off"
echo "         $BIN_DIR/ostreamy status"
