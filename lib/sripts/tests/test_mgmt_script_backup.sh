#!/bin/bash
# lib/sripts/tests/test_mgmt_script_backup.sh
#
# Regression test for do_backup() and do_update() in lib/panel/mgmt_script.sh
# (the body of the generated /usr/local/bin/remnawave_panel).
#
# The REAL function text is extracted from the file and executed in a sandbox:
#   - DIR is pointed at a temp dir (the generated script hardcodes /opt/remnawave)
#   - `docker` is a mock whose behaviour is chosen by MOCK_MODE
# Nothing outside the sandbox is touched.
#
# Usage: test_mgmt_script_backup.sh [path/to/mgmt_script.sh]
# (the optional path lets the same assertions run against another revision;
#  assertions about NEW behaviour are expected to fail on older revisions)
#
# do_backup invariants:
#   * success path: same stdout lines as before, exit status 0
#   * failed, empty or truncated pg_dump is reported, leaves no db_*.sql behind
#     and clears BACKUP_DB_OK
#   * DB user/name come from .env (quotes/CR stripped), default postgres/postgres
#   * dump format stays plain SQL (restore paths use psql, not pg_restore)
#   * new files are not world-readable; every archive gets a .sha256 sidecar
#   * backups live OUTSIDE $DIR (so whole-$DIR archivers do not nest them);
#     the legacy $DIR/backups is moved once and left as a symlink
#   * retention only touches files this function creates, only when older than
#     7 days, and always keeps the 3 newest of each kind
#   * exit status is always 0 (unchanged contract of `rp backup`)
# do_update invariant:
#   * if the DB backup did not succeed, the update stops unless the operator
#     answers y on the terminal; with no terminal the answer is "no"

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="${1:-$REPO_ROOT/lib/panel/mgmt_script.sh}"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq()   { if [ "$2" = "$3" ]; then ok; else bad "$1 (expected [$2], got [$3])"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok; else bad "$1 (missing [$3] in [$2])"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected [$3] in [$2])"; else ok; fi; }
exists(){ if [ -e "$2" ]; then ok; else bad "$1 ($2 should exist)"; fi; }
gone() { if [ ! -e "$2" ]; then ok; else bad "$1 ($2 should be gone)"; fi; }
count(){ ls -1 $2 2>/dev/null | wc -l | tr -d ' '; }

echo "== bash -n =="
bash -n "$SRC" 2>/dev/null && ok || bad "bash -n $SRC"

BK_FUNC="$(mktemp)"; UPD_FUNC="$(mktemp)"
awk '/^do_backup\(\) \{/,/^\}$/' "$SRC" > "$BK_FUNC"
awk '/^do_update\(\) \{/,/^\}$/' "$SRC" > "$UPD_FUNC"
[ -s "$BK_FUNC" ]  && ok || { bad "do_backup not found in $SRC"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
[ -s "$UPD_FUNC" ] && ok || { bad "do_update not found in $SRC"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# Sandbox factory: sets SB, MOCKBIN, BK (backup dir the function should use)
new_sandbox() {
    SB="$(mktemp -d)"
    MOCKBIN="$SB/bin"; mkdir -p "$MOCKBIN" "$SB/opt"
    BK="$SB/opt-backups"
    : > "$SB/docker_calls.log"
    cat > "$MOCKBIN/docker" <<EOF
#!/bin/bash
echo "\$*" >> "$SB/docker_calls.log"
case "\$*" in *pg_dump*) ;; *) exit 0 ;; esac
case "\${MOCK_MODE:-ok}" in
    ok)    echo "-- PostgreSQL database dump"; echo "CREATE TABLE t();"
           echo "-- PostgreSQL database dump complete"; exit 0 ;;
    trunc) echo "-- PostgreSQL database dump"; echo "CREATE TABLE t();"; exit 0 ;;
    fail)  echo "pg_dump: error: connection to server failed" >&2; exit 1 ;;
    empty) exit 0 ;;
esac
EOF
    chmod +x "$MOCKBIN/docker"
    printf 'A=1\nPOSTGRES_USER=postgres\nPOSTGRES_DB=postgres\n' > "$SB/opt/.env"
    echo "services: {}" > "$SB/opt/docker-compose.yml"
    echo "events {}"    > "$SB/opt/nginx.conf"
}

# run_backup <mode> : runs do_backup, captures stdout/stderr/rc/flag/umask
run_backup() {
    local mode="$1"
    (
        export PATH="$MOCKBIN:$PATH" MOCK_MODE="$mode"
        DIR="$SB/opt"
        GREEN=''; YELLOW=''; NC=''
        _ok()   { echo "OK: $*"; }
        _warn() { echo "WARN: $*"; }
        # shellcheck disable=SC1090
        source "$BK_FUNC"
        U0="$(umask)"
        do_backup
        echo "RC=$?" > "$SB/rc"
        echo "$U0 $(umask)" > "$SB/umask"
        echo "${BACKUP_DB_OK:-unset}" > "$SB/flag"
    ) > "$SB/out" 2> "$SB/err"
    OUT="$(cat "$SB/out")"; ERR="$(cat "$SB/err")"; RC="$(cat "$SB/rc" 2>/dev/null)"
    FLAG="$(cat "$SB/flag" 2>/dev/null)"
}

echo "== 1. success path =="
new_sandbox; run_backup ok
eq  "1a rc" "RC=0" "$RC"
has "1b db line"      "$OUT" "OK: БД → $BK/db_"
has "1c configs line" "$OUT" "OK: Конфиги → $BK/configs_"
hasnt "1d no warnings" "$OUT" "WARN"
eq  "1e stderr empty" "" "$ERR"
eq  "1e2 BACKUP_DB_OK set" "1" "$FLAG"
DUMP="$(ls "$BK"/db_*.sql 2>/dev/null | head -1)"
[ -s "$DUMP" ] && ok || bad "1f dump exists and non-empty"
has "1g plain SQL (not custom format)" "$(cat "$DUMP")" "CREATE TABLE"
hasnt "1h no -Fc flag" "$(cat "$SB/docker_calls.log")" "-Fc"
eq  "1i no leftover .err on success" "0" "$(count x "$BK/*.err")"
CFG="$(ls "$BK"/configs_*.tar.gz | head -1)"
tar -tzf "$CFG" >/dev/null 2>&1 && ok || bad "1j configs archive readable"
eq  "1k dump mode 600" "600" "$(stat -c %a "$DUMP")"
eq  "1l archive mode 600" "600" "$(stat -c %a "$CFG")"
read -r U_BEFORE U_AFTER < "$SB/umask"
eq  "1m caller umask restored after do_backup" "$U_BEFORE" "$U_AFTER"
eq  "1n backup dir mode 700" "700" "$(stat -c %a "$BK")"
eq  "1o sidecars written (2)" "2" "$(count x "$BK/*.sha256")"
( cd "$BK" && sha256sum -c ./*.sha256 >/dev/null 2>&1 ) && ok || bad "1p sha256sum -c passes"
echo "tamper" >> "$DUMP"
( cd "$BK" && sha256sum -c ./*.sha256 >/dev/null 2>&1 ) && bad "1q tampered dump must fail sha256" || ok
exists "1r nothing written inside DIR" "$SB/opt/.env"
eq  "1s DIR has no backups dir" "0" "$(ls -d "$SB"/opt/backups 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$SB"

echo "== 2. pg_dump fails =="
new_sandbox; run_backup fail
eq  "2a rc stays 0 (unchanged contract)" "RC=0" "$RC"
has "2b warning on stdout" "$OUT" "WARN: Ошибка бэкапа БД"
hasnt "2c no success line for DB" "$OUT" "OK: БД"
has "2d reason shown on stderr" "$ERR" "connection to server failed"
eq  "2e no db_*.sql left behind" "0" "$(count x "$BK/db_*.sql")"
has "2f configs still backed up" "$OUT" "OK: Конфиги"
eq  "2g BACKUP_DB_OK cleared" "0" "$FLAG"
eq  "2h no db sidecar" "0" "$(count x "$BK/db_*.sha256")"
rm -rf "$SB"

echo "== 3. pg_dump exits 0 but output is empty or truncated =="
new_sandbox; run_backup empty
has "3a empty treated as failure" "$OUT" "WARN: Ошибка бэкапа БД"
eq  "3b empty file removed" "0" "$(count x "$BK/db_*.sql")"
eq  "3b2 flag cleared" "0" "$FLAG"
rm -rf "$SB"
new_sandbox; run_backup trunc
has "3c truncated treated as failure" "$OUT" "WARN: Ошибка бэкапа БД"
hasnt "3d no success line" "$OUT" "OK: БД"
has "3e reason on stderr" "$ERR" "дамп неполный"
eq  "3f truncated file removed" "0" "$(count x "$BK/db_*.sql")"
eq  "3g flag cleared" "0" "$FLAG"
rm -rf "$SB"

echo "== 4. credentials from .env =="
new_sandbox
printf 'POSTGRES_USER="rwuser"\nPOSTGRES_DB='"'"'rwdb'"'"'\n' > "$SB/opt/.env"
run_backup ok
has "4a user from .env, quotes stripped" "$(cat "$SB/docker_calls.log")" "pg_dump -U rwuser rwdb"
rm -rf "$SB"
new_sandbox; printf 'POSTGRES_USER=crlf\r\nPOSTGRES_DB=crlfdb\r\n' > "$SB/opt/.env"
run_backup ok
has "4b CRLF .env tolerated" "$(cat "$SB/docker_calls.log")" "pg_dump -U crlf crlfdb"
rm -rf "$SB"
new_sandbox; rm -f "$SB/opt/.env"
run_backup ok
has "4c missing .env falls back to postgres postgres" "$(cat "$SB/docker_calls.log")" "pg_dump -U postgres postgres"
has "4d missing .env reported for configs" "$OUT" "WARN: Ошибка бэкапа конфигов"
rm -rf "$SB"
new_sandbox; printf 'A=1\n' > "$SB/opt/.env"
run_backup ok
has "4e .env without keys falls back to postgres postgres" "$(cat "$SB/docker_calls.log")" "pg_dump -U postgres postgres"
rm -rf "$SB"

echo "== 5. Caddy layout uses Caddyfile =="
new_sandbox; rm -f "$SB/opt/nginx.conf"; echo ":443 {}" > "$SB/opt/Caddyfile"
run_backup ok
has "5a configs OK with Caddyfile" "$OUT" "OK: Конфиги"
hasnt "5b no config warning" "$OUT" "WARN"
tar -tzf "$(ls "$BK"/configs_*.tar.gz | head -1)" 2>/dev/null | grep -q Caddyfile && ok || bad "5c Caddyfile is inside archive"
rm -rf "$SB"

echo "== 6. backups live outside DIR; legacy dir is migrated once =="
new_sandbox; mkdir -p "$SB/opt/backups"; echo "old-dump" > "$SB/opt/backups/db_20200101_000000.sql"
run_backup ok
[ -L "$SB/opt/backups" ] && ok || bad "6a legacy path is now a symlink"
eq  "6b symlink points to new dir" "$BK" "$(readlink "$SB/opt/backups")"
exists "6c legacy file moved" "$BK/db_20200101_000000.sql"
eq  "6d legacy file reachable via old path" "old-dump" "$(cat "$SB/opt/backups/db_20200101_000000.sql")"
eq  "6e new dump lands in new dir" "1" "$(count x "$BK/db_2*.sql" | awk '$1>=1{print 1}')"
eq  "6f moved dir mode 700" "700" "$(stat -c %a "$BK")"
run_backup ok
eq  "6g second run does not break the symlink" "$BK" "$(readlink "$SB/opt/backups")"
rm -rf "$SB"
new_sandbox; mkdir -p "$SB/opt/backups" "$BK"; echo keep > "$SB/opt/backups/legacy.txt"
run_backup ok
[ -d "$SB/opt/backups" ] && [ ! -L "$SB/opt/backups" ] && ok || bad "6h both dirs exist: legacy left untouched"
exists "6i legacy content intact" "$SB/opt/backups/legacy.txt"
rm -rf "$SB"
new_sandbox; export RP_BACKUP_DIR="$SB/custom-bk"
run_backup ok
exists "6j RP_BACKUP_DIR override honoured" "$SB/custom-bk"
eq  "6k default location not used with override" "0" "$(ls -d "$BK" 2>/dev/null | wc -l | tr -d ' ')"
unset RP_BACKUP_DIR; rm -rf "$SB"

echo "== 7. retention: own files, >7 days, newest 3 always kept =="
new_sandbox; mkdir -p "$BK"
for i in 1 2 3 4 5; do
    d=$((30 - i))   # 29..25 days old
    for f in "db_2020010${i}_000000.sql" "configs_2020010${i}_000000.tar.gz"; do
        echo x > "$BK/$f"; echo "h $f" > "$BK/$f.sha256"; touch -d "$d days ago" "$BK/$f" "$BK/$f.sha256"
    done
done
touch -d '10 days ago' "$BK/db_20200101_000000.err" "$BK/user_manual_copy.tar" "$BK/notes.txt"
run_backup ok
eq  "7a dumps: new + 2 newest old (3 total)" "3" "$(count x "$BK/db_*.sql")"
eq  "7b configs: new + 2 newest old (3 total)" "3" "$(count x "$BK/configs_*.tar.gz")"
# ages: ..._01 = 29 days (oldest) ... ..._05 = 25 days (newest of the old ones)
gone   "7c oldest dump removed" "$BK/db_20200101_000000.sql"
gone   "7d its sidecar removed" "$BK/db_20200101_000000.sql.sha256"
gone   "7d2 3rd-newest old dump (beyond keep-3) removed" "$BK/db_20200103_000000.sql"
exists "7e 2nd-newest old dump kept" "$BK/db_20200104_000000.sql"
exists "7e2 newest old dump kept" "$BK/db_20200105_000000.sql"
exists "7e3 kept dump keeps its sidecar" "$BK/db_20200105_000000.sql.sha256"
gone   "7e4 configs: oldest removed with sidecar" "$BK/configs_20200101_000000.tar.gz.sha256"
gone   "7f old .err removed" "$BK/db_20200101_000000.err"
exists "7g foreign old file preserved" "$BK/user_manual_copy.tar"
exists "7h foreign old file preserved (2)" "$BK/notes.txt"
[ -d "$BK" ] && ok || bad "7i backup dir survives"
rm -rf "$SB"
new_sandbox; mkdir -p "$BK"
for i in 1 2 3 4; do echo x > "$BK/db_2020010${i}_000000.sql"; touch -d "$((20 + i)) days ago" "$BK/db_2020010${i}_000000.sql"; done
run_backup fail
eq  "7j failing backups never wipe the last good dumps (3 kept)" "3" "$(count x "$BK/db_*.sql")"
exists "7k newest old dump kept" "$BK/db_20200101_000000.sql"
gone   "7l oldest beyond the 3rd removed" "$BK/db_20200104_000000.sql"
rm -rf "$SB"
new_sandbox; mkdir -p "$BK"
for i in 1 2 3 4 5; do echo x > "$BK/db_2020010${i}_000000.sql"; touch -d "$i days ago" "$BK/db_2020010${i}_000000.sql"; done
run_backup ok
eq  "7m age rule: nothing older than 7 days, nothing removed (5 old + 1 new)" "6" "$(count x "$BK/db_*.sql")"
rm -rf "$SB"

echo "== 8. do_update stops when the DB backup did not succeed =="
HAVE_SCRIPT=0; command -v script >/dev/null 2>&1 && HAVE_SCRIPT=1
HAVE_SETSID=0; command -v setsid >/dev/null 2>&1 && HAVE_SETSID=1
new_sandbox
H="$SB/upd_harness.sh"; LOG="$SB/upd.log"
cat > "$H" <<EOF
DIR="$SB/opt"; GREEN=''; YELLOW=''; NC=''
_ok()   { echo "OK: \$*"; }
_warn() { echo "WARN: \$*"; }
_info() { echo "INFO: \$*"; }
_spinner() { wait "\$1" 2>/dev/null; }
do_backup() { echo backup >> "$LOG"; BACKUP_DB_OK="\$FLAG"; }
_migrate_env_for_remnawave_v2() { echo migrate >> "$LOG"; return 0; }
docker() { echo "docker \$*" >> "$LOG"; return 0; }
source "$UPD_FUNC"
do_update
echo "RC=\$?"
EOF
run_upd() { # <flag> ; stdin is the operator's answer when a tty is emulated
    : > "$LOG"
}
# 8a: backup OK -> proceeds without asking
: > "$LOG"; U="$(FLAG=1 bash "$H" </dev/null 2>/dev/null)"
has "8a backup ok: update proceeds" "$U" "OK: Обновлено"
has "8b backup ok: no prompt" "$(cat "$LOG")" "docker compose pull"
hasnt "8c backup ok: no warning" "$U" "Бэкап БД не создан"
has "8c2 rc 0" "$U" "RC=0"
# 8d: backup failed, no terminal -> abort
if [ "$HAVE_SETSID" = 1 ]; then
    : > "$LOG"; U="$(FLAG=0 setsid -w bash "$H" </dev/null 2>/dev/null)"
    has   "8d failed backup, no tty: warns" "$U" "WARN: Бэкап БД не создан."
    has   "8e failed backup, no tty: aborts" "$U" "INFO: Обновление отменено"
    has   "8f failed backup, no tty: rc 1" "$U" "RC=1"
    hasnt "8g failed backup, no tty: no pull" "$(cat "$LOG")" "docker compose pull"
    hasnt "8h failed backup, no tty: env migration not reached" "$(cat "$LOG")" "migrate"
else
    echo "  (skip 8d-8h: setsid not available)"
fi
# 8i-8m: terminal emulated through script(1)
if [ "$HAVE_SCRIPT" = 1 ]; then
    : > "$LOG"; U="$(printf 'y\n' | FLAG=0 script -qec "bash $H" /dev/null 2>/dev/null)"
    has   "8i answer y: proceeds" "$U" "OK: Обновлено"
    has   "8j answer y: pulls images" "$(cat "$LOG")" "docker compose pull"
    : > "$LOG"; U="$(printf 'n\n' | FLAG=0 script -qec "bash $H" /dev/null 2>/dev/null)"
    has   "8k answer n: aborts" "$U" "Обновление отменено"
    hasnt "8l answer n: no pull" "$(cat "$LOG")" "docker compose pull"
    : > "$LOG"; U="$(printf '\n' | FLAG=0 script -qec "bash $H" /dev/null 2>/dev/null)"
    has   "8m empty answer defaults to no" "$U" "Обновление отменено"
else
    echo "  (skip 8i-8m: script(1) not available)"
fi
rm -rf "$SB"

rm -f "$BK_FUNC" "$UPD_FUNC"
echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
