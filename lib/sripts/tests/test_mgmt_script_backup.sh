#!/usr/bin/env bash
# Regression tests for do_backup() and the do_update() backup guard.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="${1:-$ROOT/lib/panel/mgmt_script.sh}"
PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $*"; }
eq(){ [ "$2" = "$3" ] && ok || bad "$1 (expected [$2], got [$3])"; }
has(){ printf '%s' "$2" | grep -qF -- "$3" && ok || bad "$1 (missing [$3])"; }
bash -n "$SRC" && ok || bad "mgmt_script.sh syntax"
FUNC="$(mktemp)"
awk '/^do_backup\(\) \{/,/^\}$/' "$SRC" > "$FUNC"
[ -s "$FUNC" ] && ok || { bad "do_backup not found"; exit 1; }
SB="$(mktemp -d)"
trap 'rm -rf "$SB" "$FUNC"' EXIT
mkdir -p "$SB/bin" "$SB/opt"
BK="$SB/opt-backups"
cat > "$SB/bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "${MOCK_MODE:-ok}" in
  ok) echo "-- PostgreSQL database dump"; echo "CREATE TABLE t();"; echo "-- PostgreSQL database dump complete";;
  truncated) echo "-- PostgreSQL database dump"; echo "CREATE TABLE t();";;
  empty) exit 0;;
  fail) echo "mock pg_dump failure" >&2; exit 1;;
esac
MOCK
chmod +x "$SB/bin/docker"
printf 'POSTGRES_USER="rwuser"\nPOSTGRES_DB=rwdb\n' > "$SB/opt/.env"
echo 'services: {}' > "$SB/opt/docker-compose.yml"
echo 'events {}' > "$SB/opt/nginx.conf"
run_backup(){
  local mode="$1"
  (
    export PATH="$SB/bin:$PATH" MOCK_MODE="$mode"
    DIR="$SB/opt"; _ok(){ echo "OK: $*"; }; _warn(){ echo "WARN: $*"; }
    source "$FUNC"; do_backup
    echo "FLAG=${BACKUP_DB_OK:-unset}"
    echo "UMASK=$(umask)"
  ) > "$SB/out" 2> "$SB/err"
  OUT="$(cat "$SB/out")"; ERR="$(cat "$SB/err")"
}
echo "== successful backup =="
run_backup ok
has "DB success" "$OUT" "OK: БД"
has "config success" "$OUT" "OK: Конфиги"
has "DB flag set" "$OUT" "FLAG=1"
DUMP="$(find "$BK" -maxdepth 1 -name 'db_*.sql' -print -quit)"
CFG="$(find "$BK" -maxdepth 1 -name 'configs_*.tar.gz' -print -quit)"
[ -s "$DUMP" ] && ok || bad "non-empty dump exists"
[ -s "$CFG" ] && tar -tzf "$CFG" >/dev/null 2>&1 && ok || bad "valid config archive"
eq "backup dir permissions" 700 "$(stat -c %a "$BK")"
eq "dump permissions" 600 "$(stat -c %a "$DUMP")"
eq "archive permissions" 600 "$(stat -c %a "$CFG")"
[ -s "$DUMP.sha256" ] && [ -s "$CFG.sha256" ] && ok || bad "SHA256 sidecars exist"
( cd "$BK" && sha256sum -c ./*.sha256 >/dev/null 2>&1 ) && ok || bad "SHA256 verification"
has "DB credentials from env" "$(cat "$SB/out")" "FLAG=1"
echo "== failed, empty and truncated dumps =="
for mode in fail empty truncated; do
  rm -f "$BK"/db_*.sql "$BK"/db_*.sql.sha256
  run_backup "$mode"
  has "$mode treated as failure" "$OUT" "WARN: Ошибка бэкапа БД"
  has "$mode clears success flag" "$OUT" "FLAG=0"
  [ -z "$(find "$BK" -maxdepth 1 -name 'db_*.sql' -print -quit)" ] && ok || bad "$mode dump removed"
done
echo "== update guard source contract =="
grep -q 'BACKUP_DB_OK:-1' "$SRC" && ok || bad "update checks BACKUP_DB_OK"
grep -q 'Обновление отменено' "$SRC" && ok || bad "update can abort without DB backup"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
