#!/bin/bash
# Remove ostreamy's runtime pieces. Leaves your config and Sunshine's config alone
# unless --purge is given.
set -euo pipefail

MARK_BEGIN="# >>> ostreamy >>>"
MARK_END="# <<< ostreamy <<<"
HYPR_CONF="$HOME/.config/hypr/monitors.lua"
SUNSHINE_CONF="$HOME/.config/sunshine/sunshine.conf"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ostreamy"

purge=0
[ "${1:-}" = "--purge" ] && purge=1

say() { printf '%-6s %s\n' "$1" "$2"; }

systemctl --user disable --now ostreamy-watch.service >/dev/null 2>&1 \
  && say SET "watcher disabled" || say INFO "watcher was not running"

rm -f "$HOME/.local/bin/ostreamy" "$HOME/.local/bin/ostreamy-watch" "$HOME/.local/bin/ostreamy-verify"
rm -rf "$HOME/.local/lib/ostreamy"
rm -f "$HOME/.config/systemd/user/ostreamy-watch.service"
systemctl --user daemon-reload
say SET "scripts and unit removed"

strip_block() {
  local file="$1" latest tmp
  [ -f "$file" ] || return 0
  grep -qF "$MARK_BEGIN" "$file" || return 0
  cp "$file" "$file.bak.$(date +%s)"
  latest=$(ls -t "$file".bak.* | head -1)
  tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    !skip {print}
  ' "$latest" > "$tmp"
  mv "$tmp" "$file"
  say SET "removed managed block from $file"
}

strip_block "$HYPR_CONF"
strip_block "$SUNSHINE_CONF"
hyprctl reload >/dev/null 2>&1 || true
hyprctl output remove STREAM >/dev/null 2>&1 || true

if [ "$purge" -eq 1 ]; then
  rm -rf "$CONF_DIR"
  say SET "purged $CONF_DIR"
else
  say INFO "kept $CONF_DIR (use --purge to delete)"
fi

echo
say OK "done. Restart Sunshine or reboot to apply."
