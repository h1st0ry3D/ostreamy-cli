#!/bin/bash
# Remove Ostreamy's runtime pieces. Leaves your config and Sunshine's config alone
# unless --purge is given.
set -euo pipefail

MARK_BEGIN_INI="# >>> ostreamy >>>"
MARK_END_INI="# <<< ostreamy <<<"
MARK_BEGIN_LUA="-- >>> ostreamy >>>"
MARK_END_LUA="-- <<< ostreamy <<<"
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
  local file="$1" latest tmp b e
  case "$file" in
    *.lua) b="$MARK_BEGIN_LUA"; e="$MARK_END_LUA" ;;
    *)     b="$MARK_BEGIN_INI"; e="$MARK_END_INI" ;;
  esac
  [ -f "$file" ] || return 0
  grep -qF "$b" "$file" || return 0
  if ! cp "$file" "$file.bak.$(date +%s)"; then
    say FAIL "could not back up $file, leaving it untouched"
    return 1
  fi
  latest=$(ls -t "$file".bak.* 2>/dev/null | head -1)
  [ -n "$latest" ] || { say FAIL "no backup for $file, leaving it untouched"; return 1; }
  tmp=$(mktemp)
  awk -v b="$b" -v e="$e" '
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
