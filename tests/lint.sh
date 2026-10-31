#!/bin/bash
# Static checks: shell syntax, optional shellcheck, and hygiene greps.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

mapfile -t scripts < <(git ls-files '*.sh' 'bin/*' 'lib/ostreamy/*.sh' 2>/dev/null || true)
[ "${#scripts[@]}" -gt 0 ] || { echo "no scripts found"; exit 1; }

for f in "${scripts[@]}"; do
  if bash -n "$f"; then ok "syntax: $f"; else bad "syntax: $f"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "${scripts[@]}"; then ok "shellcheck (warning)"; else bad "shellcheck"; fi
else
  echo "info shellcheck not installed, skipped"
fi

if git grep -qE '/home/[a-z0-9_-]+' -- . ':!docs/*' 2>/dev/null; then
  bad "absolute /home path in tracked files"
else
  ok "no absolute home paths"
fi

# install.sh legitimately mentions the pre-rename unit while retiring it.
if git grep -qE 'hypr-stream-|sunshine-stream-watch' -- bin lib uninstall.sh systemd 2>/dev/null; then
  bad "stale legacy script names"
else
  ok "no stale legacy names"
fi

echo
[ "$fail" -eq 0 ] && echo "lint: PASS" || echo "lint: FAIL"
exit "$fail"
