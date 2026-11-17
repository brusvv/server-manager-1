#!/bin/bash
# lib/sripts/tests/test_migrate_backup_restore.sh
#
# panel_backup_restore() (lib/migrate.sh) installs and launches a third-party
# script AS ROOT. Regression coverage for:
#   * it points at distillium/remnawave-backup-restore at a fixed tag (the
#     previous URL, Remnawave/backup-restore, returns 404)
#   * it looks for / launches the command that script really installs:
#     rw-backup (not remnawave-backup)
#   * the downloaded file is run only if its SHA256 equals the pinned value;
#     a mismatch or a failed download never executes anything and leaves no
#     temp file behind
#   * the exit status of the launched script is propagated
#
# The REAL function is extracted from lib/migrate.sh. curl is mocked (no
# network); rw-backup is mocked via PATH. The only transformation applied to
# the function text is swapping the pinned hash literal for the hash of the
# test payload, so the "hash matches" branch can be exercised offline; the
# literal's presence and format in the real source are asserted separately.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="${1:-$REPO_ROOT/lib/migrate.sh}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq()   { if [ "$2" = "$3" ]; then ok; else bad "$1 (expected [$2], got [$3])"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok; else bad "$1 (missing [$3] in [$2])"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected [$3] in [$2])"; else ok; fi; }

echo "== bash -n =="
bash -n "$SRC" 2>/dev/null && ok || bad "bash -n $SRC"

FUNC="$(mktemp)"
awk '/^panel_backup_restore\(\) \{/,/^\}$/' "$SRC" > "$FUNC"
[ -s "$FUNC" ] && ok || { bad "panel_backup_restore not found"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

echo "== 1. source facts =="
TXT="$(cat "$FUNC")"
has   "1a distillium repo"        "$TXT" "raw.githubusercontent.com/distillium/remnawave-backup-restore/"
hasnt "1b dead URL gone"          "$TXT" "Remnawave/backup-restore"
hasnt "1c not tracking main"      "$TXT" "/main/backup-restore.sh"
has   "1d fixed tag in URL"       "$TXT" '/${rw_tag}/backup-restore.sh'
has   "1e command is rw-backup"   "$TXT" "command -v rw-backup"
hasnt "1f old command lookup gone" "$TXT" "command -v remnawave-backup"
eq    "1g exactly one pinned sha256 literal" "1" "$(grep -c 'rw_sha256="[0-9a-f]\{64\}"' "$FUNC")"
hasnt "1h no pipe-to-shell hint"  "$TXT" "| bash"

GOOD_PAYLOAD='#!/bin/bash
echo PAYLOAD-RAN "$@"
exit 7'
GOOD_HASH="$(printf '%s\n' "$GOOD_PAYLOAD" | sha256sum | awk '{print $1}')"

# run_case <curl-mode: ok|bad|fail> <rw-backup: yes|no> -> OUT, RC, SB, CURL_CALLS
run_case() {
    local cmode="$1" have_rw="$2"
    SB="$(mktemp -d)"; mkdir -p "$SB/bin" "$SB/tmp"
    if [ "$have_rw" = yes ]; then
        printf '#!/bin/bash\necho RW-BACKUP-MENU\nexit 3\n' > "$SB/bin/rw-backup"; chmod +x "$SB/bin/rw-backup"
    fi
    : > "$SB/curl.calls"
    sed "s/rw_sha256=\"[0-9a-f]\{64\}\"/rw_sha256=\"$GOOD_HASH\"/" "$FUNC" > "$SB/func.sh"
    OUT="$(
        export PATH="$SB/bin:/usr/bin:/bin" TMPDIR="$SB/tmp"
        header(){ echo "HDR: $*"; }; info(){ echo "INFO: $*"; }
        ok(){ echo "OK: $*"; }; warn(){ echo "WARN: $*"; }
        CYAN=''; NC=''
        curl() {
            local out="" a prev=""
            for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
            echo "$*" >> "$SB/curl.calls"
            case "$cmode" in
                ok)   printf '%s\n' "$GOOD_PAYLOAD" > "$out"; return 0 ;;
                bad)  printf '#!/bin/bash\necho TAMPERED-RAN\n' > "$out"; return 0 ;;
                fail) return 22 ;;
            esac
        }
        # shellcheck disable=SC1090
        source "$SB/func.sh"
        panel_backup_restore
        echo "RC=$?"
    )"
    RC="$(printf '%s\n' "$OUT" | grep -o 'RC=[0-9]*' | tail -1)"
    CURL_CALLS="$(cat "$SB/curl.calls")"
    LEFTOVER="$(ls -1 "$SB/tmp" 2>/dev/null | wc -l | tr -d ' ')"
}

echo "== 2. already installed: runs rw-backup, downloads nothing =="
run_case ok yes
has   "2a menu launched"          "$OUT" "RW-BACKUP-MENU"
eq    "2b no download attempted"  "" "$CURL_CALLS"
eq    "2c rw-backup status propagated" "RC=3" "$RC"
rm -rf "$SB"

echo "== 3. fresh install: hash matches =="
run_case ok no
has   "3a downloads from tagged distillium URL" "$CURL_CALLS" "distillium/remnawave-backup-restore/4.3.0/backup-restore.sh"
has   "3b payload executed"       "$OUT" "PAYLOAD-RAN"
has   "3c success message"        "$OUT" "контрольная сумма совпала"
eq    "3d payload status propagated" "RC=7" "$RC"
eq    "3e temp file removed"      "0" "$LEFTOVER"
rm -rf "$SB"

echo "== 4. fresh install: hash mismatch =="
run_case bad no
hasnt "4a tampered payload NOT executed" "$OUT" "TAMPERED-RAN"
has   "4b mismatch reported"      "$OUT" "WARN: Контрольная сумма скрипта не совпала"
eq    "4c rc 1"                   "RC=1" "$RC"
eq    "4d temp file removed"      "0" "$LEFTOVER"
rm -rf "$SB"

echo "== 5. fresh install: download fails =="
run_case fail no
has   "5a failure reported"       "$OUT" "WARN: Не удалось скачать скрипт"
has   "5b manual hint uses the tagged URL" "$OUT" "distillium/remnawave-backup-restore/4.3.0/backup-restore.sh"
hasnt "5c manual hint does not pipe into bash" "$OUT" "| bash"
eq    "5d rc 1"                   "RC=1" "$RC"
eq    "5e temp file removed"      "0" "$LEFTOVER"
rm -rf "$SB"

rm -f "$FUNC"
echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
