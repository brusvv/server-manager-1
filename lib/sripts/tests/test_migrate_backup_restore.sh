#!/usr/bin/env bash
# Regression checks for the pinned remnawave-backup-restore bootstrap.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="${1:-$ROOT/lib/migrate.sh}"
PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $*"; }
has(){ printf '%s' "$2" | grep -qF -- "$3" && ok || bad "$1"; }
hasnt(){ printf '%s' "$2" | grep -qF -- "$3" && bad "$1" || ok; }
bash -n "$SRC" && ok || bad "migrate.sh syntax"
FUNC="$(mktemp)"
trap 'rm -f "$FUNC"' EXIT
awk '/^panel_backup_restore\(\) \{/,/^\}$/' "$SRC" > "$FUNC"
[ -s "$FUNC" ] && ok || { bad "panel_backup_restore not found"; exit 1; }
T="$(cat "$FUNC")"
has "uses distillium source" "$T" "raw.githubusercontent.com/distillium/remnawave-backup-restore/"
has "pins release tag" "$T" 'local rw_tag="4.3.0"'
has "pins SHA256" "$T" 'local rw_sha256="ae36fa1df8a5998c599a643105b9386dbab6c3d25ef4381f77cdfdc5d841e6b2"'
has "uses installed command" "$T" "command -v rw-backup"
has "checks downloaded file hash" "$T" 'if [ "$actual" != "$rw_sha256" ]'
has "runs only verified temp file" "$T" '"$tmp"; rc=$?'
has "cleans temp file" "$T" 'rm -f "$tmp"'
hasnt "old unpinned upstream URL removed" "$T" "Remnawave/backup-restore/main"
hasnt "no pipe-to-shell bootstrap" "$T" "| bash"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
