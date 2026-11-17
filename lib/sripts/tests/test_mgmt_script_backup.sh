#!/bin/bash
# lib/sripts/tests/test_mgmt_script_backup.sh
#
# Regression test for do_backup() in lib/panel/mgmt_script.sh (the body of the
# generated /usr/local/bin/remnawave_panel).
#
# The REAL function text is extracted from the file and executed in a sandbox:
#   - DIR is pointed at a temp dir (the generated script hardcodes /opt/remnawave)
#   - docker is a mock whose behaviour is chosen by MOCK_MODE
# Nothing outside the sandbox is touched.
#
# Usage: test_mgmt_script_backup.sh [path/to/mgmt_script.sh]
# (the optional path lets the same assertions run against another revision)
#
# Invariants checked:
#   * success path: same stdout lines as before, exit status 0
#   * a failed or empty pg_dump is reported and leaves no empty db_*.sql behind
#   * DB user/name come from .env (quotes stripped), default postgres/postgres
#   * dump format stays plain SQL (restore paths use psql, not pg_restore)
#   * new files are not world-readable
#   * retention only deletes backup files this function creates
#   * exit status is always 0 (unchanged contract: do_update calls do_backup)

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="${1:-$REPO_ROOT/lib/panel/mgmt_script.sh}"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq()   { # name expected actual
    if [ "$2" = "$3" ]; then ok; else bad "$1 (expected [$2], got [$3])"; fi
}
has()  { # name haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then ok; else bad "$1 (missing [$3] in [$2])"; fi
}
hasnt() {
    if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected [$3] in [$2])"; else ok; fi
}

echo "== bash -n =="
bash -n "$SRC" 2>/dev/null && ok || bad "bash -n $SRC"

FUNC_FILE="$(mktemp)"
awk '/^do_backup\(\) \{/,/^\}$/' "$SRC" > "$FUNC_FILE"
[ -s "$FUNC_FILE" ] && ok || { bad "do_backup not found in $SRC"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

new_sandbox() {
    SB="$(mktemp -d)"
    MOCKBIN="$SB/bin"; mkdir -p "$MOCKBIN" "$SB/opt"
    : > "$SB/docker_calls.log"
    cat > "$MOCKBIN/docker" <<EOF
#!/bin/bash
echo "\$*" >> "$SB/docker_calls.log"
case "\${MOCK_MODE:-ok}" in
    ok)    echo "-- PostgreSQL database dump"; echo "CREATE TABLE t();" ; exit 0 ;;
    fail)  echo "pg_dump: error: connection to server failed" >&2; exit 1 ;;
    empty) exit 0 ;;
esac
EOF
    chmod +x "$MOCKBIN/docker"
    printf 'A=1\nPOSTGRES_USER=postgres\nPOSTGRES_DB=postgres\n' > "$SB/opt/.env"
    echo "services: {}" > "$SB/opt/docker-compose.yml"
    echo "events {}"    > "$SB/opt/nginx.conf"
}
run_backup() {
    local mode="$1"
    (
        export PATH="$MOCKBIN:$PATH" MOCK_MODE="$mode"
        DIR="$SB/opt"; GREEN=''; YELLOW=''; NC=''
        _ok() { echo "OK: $*"; }; _warn() { echo "WARN: $*"; }
        source "$FUNC_FILE"
        U0="$(umask)"; do_backup
        echo "RC=$?" > "$SB/rc"; echo "$U0 $(umask)" > "$SB/umask"
    ) > "$SB/out" 2> "$SB/err"
    OUT="$(cat "$SB/out")"; ERR="$(cat "$SB/err")"; RC="$(cat "$SB/rc" 2>/dev/null)"
}

echo "== 1. success path =="
new_sandbox; run_backup ok
eq "1a rc" "RC=0" "$RC"
has "1b db line" "$OUT" "OK: БД → $SB/opt/backups/db_"
has "1c configs line" "$OUT" "OK: Конфиги → $SB/opt/backups/configs_"
hasnt "1d no warnings" "$OUT" "WARN"
eq "1e stderr empty" "" "$ERR"
DUMP="$(ls "$SB"/opt/backups/db_*.sql 2>/dev/null | head -1)"
[ -s "$DUMP" ] && ok || bad "1f dump exists and non-empty"
has "1g plain SQL" "$(cat "$DUMP")" "CREATE TABLE"
hasnt "1h no -Fc flag" "$(cat "$SB/docker_calls.log")" "-Fc"
eq "1i no leftover .err on success" "0" "$(ls "$SB"/opt/backups/*.err 2>/dev/null | wc -l | tr -d ' ')"
tar -tzf "$(ls "$SB"/opt/backups/configs_*.tar.gz | head -1)" >/dev/null 2>&1 && ok || bad "1j configs archive readable"
eq "1k dump mode 600" "600" "$(stat -c %a "$DUMP")"
eq "1l archive mode 600" "600" "$(stat -c %a "$(ls "$SB"/opt/backups/configs_*.tar.gz | head -1)")"
read -r U_BEFORE U_AFTER < "$SB/umask"
eq "1m caller umask restored" "$U_BEFORE" "$U_AFTER"
rm -rf "$SB"

echo "== 2. pg_dump fails =="
new_sandbox; run_backup fail
eq "2a rc stays 0" "RC=0" "$RC"
has "2b warning on stdout" "$OUT" "WARN: Ошибка бэкапа БД"
hasnt "2c no success line for DB" "$OUT" "OK: БД"
has "2d reason shown on stderr" "$ERR" "connection to server failed"
eq "2e no db dump left" "0" "$(ls "$SB"/opt/backups/db_*.sql 2>/dev/null | wc -l | tr -d ' ')"
has "2f configs still backed up" "$OUT" "OK: Конфиги"
rm -rf "$SB"

echo "== 3. pg_dump exits 0 but produces nothing =="
new_sandbox; run_backup empty
has "3a treated as failure" "$OUT" "WARN: Ошибка бэкапа БД"
eq "3b empty file removed" "0" "$(ls "$SB"/opt/backups/db_*.sql 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$SB"

echo "== 4. credentials from .env =="
new_sandbox
printf 'POSTGRES_USER="rwuser"\nPOSTGRES_DB='\''rwdb'\''\n' > "$SB/opt/.env"
run_backup ok
has "4a user and db from .env" "$(cat "$SB/docker_calls.log")" "pg_dump -U rwuser rwdb"
rm -rf "$SB"
new_sandbox; printf 'POSTGRES_USER=crlf\r\nPOSTGRES_DB=crlfdb\r\n' > "$SB/opt/.env"
run_backup ok
has "4b CRLF .env tolerated" "$(cat "$SB/docker_calls.log")" "pg_dump -U crlf crlfdb"
rm -rf "$SB"
new_sandbox; rm -f "$SB/opt/.env"
run_backup ok
has "4c missing .env fallback" "$(cat "$SB/docker_calls.log")" "pg_dump -U postgres postgres"
has "4d missing .env config warning" "$OUT" "WARN: Ошибка бэкапа конфигов"
rm -rf "$SB"
new_sandbox; printf 'A=1\n' > "$SB/opt/.env"
run_backup ok
has "4e missing keys fallback" "$(cat "$SB/docker_calls.log")" "pg_dump -U postgres postgres"
rm -rf "$SB"

echo "== 5. Caddy layout =="
new_sandbox; rm -f "$SB/opt/nginx.conf"; echo ":443 {}" > "$SB/opt/Caddyfile"
run_backup ok
has "5a configs OK with Caddyfile" "$OUT" "OK: Конфиги"
hasnt "5b no config warning" "$OUT" "WARN"
tar -tzf "$(ls "$SB"/opt/backups/configs_*.tar.gz | head -1)" 2>/dev/null | grep -q Caddyfile && ok || bad "5c Caddyfile archived"
rm -rf "$SB"

echo "== 6. retention =="
new_sandbox; mkdir -p "$SB/opt/backups"; B="$SB/opt/backups"
touch -d '10 days ago' "$B/db_20200101_000000.sql" "$B/configs_20200101_000000.tar.gz" "$B/db_20200101_000000.err"
touch -d '10 days ago' "$B/user_manual_copy.tar" "$B/notes.txt"
touch -d '2 days ago' "$B/db_recent.sql"
run_backup ok
[ ! -e "$B/db_20200101_000000.sql" ] && ok || bad "6a old db removed"
[ ! -e "$B/configs_20200101_000000.tar.gz" ] && ok || bad "6b old configs removed"
[ ! -e "$B/db_20200101_000000.err" ] && ok || bad "6c old err removed"
[ -e "$B/user_manual_copy.tar" ] && ok || bad "6d foreign file preserved"
[ -e "$B/notes.txt" ] && ok || bad "6e foreign file preserved (2)"
[ -e "$B/db_recent.sql" ] && ok || bad "6f recent dump preserved"
[ -d "$B" ] && ok || bad "6g backups dir survives"
rm -rf "$SB"

echo "== 7. caller continues after backup =="
new_sandbox
OUT7="$(export PATH="$MOCKBIN:$PATH" MOCK_MODE=fail
    DIR="$SB/opt"; GREEN=''; YELLOW=''; NC=''
    _ok() { echo "OK: $*"; }; _warn() { echo "WARN: $*"; }
    source "$FUNC_FILE"; do_backup 2>/dev/null; echo "after-backup-continues")"
has "7a flow continues after failed backup" "$OUT7" "after-backup-continues"
rm -rf "$SB"; rm -f "$FUNC_FILE"
echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
