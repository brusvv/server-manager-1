# shellcheck shell=bash
# lib/users_backup.sh — Users-only transfer; prompts live here, data work in Python.

users_backup_restore_menu() {
    local _root="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local _worker="${_root}/lib/panel/py/users_backup.py"
    local _backup_dir="${RP_BACKUP_DIR:-/opt/remnawave-backups}"
    local _choice

    [ -f "$_worker" ] || { warn "Users-only модуль не найден: $_worker"; return 1; }
    command -v python3 >/dev/null 2>&1 || { warn "Требуется Python 3"; return 1; }

    while true; do
        echo ""
        header "Users-only Backup / Restore"
        echo "  1) Экспортировать пользователей в архив"
        echo "  2) Импортировать пользователей из архива"
        echo "  0) Назад"
        read -rp "  Выбор: " _choice < /dev/tty
        case "$_choice" in
            1)
                local _out="${_backup_dir}/users_$(date +%Y%m%d_%H%M%S).rwusers"
                local _answer=""
                read -rp "  Файл архива [${_out}]: " _answer < /dev/tty
                [ -n "$_answer" ] && _out="$_answer"
                python3 "$_worker" export --output "$_out" || warn "Экспорт не завершён"
                read -rp "  Нажмите Enter..." < /dev/tty
                ;;
            2)
                local _input="" _squad_choice="" _selected_uuid="" _answer=""
                read -rp "  Путь к .rwusers архиву: " _input < /dev/tty
                [ -n "$_input" ] || continue
                if ! python3 "$_worker" preview --input "$_input"; then
                    warn "Проверка архива не прошла"
                    read -rp "  Нажмите Enter..." < /dev/tty
                    continue
                fi
                local _squads_output=""
                if ! _squads_output=$(python3 "$_worker" squads); then
                    warn "Не удалось получить список Internal Squads"
                    read -rp "  Нажмите Enter..." < /dev/tty
                    continue
                fi
                local -a _squad_rows=()
                if [ -n "$_squads_output" ]; then
                    mapfile -t _squad_rows <<< "$_squads_output"
                fi
                if [ "${#_squad_rows[@]}" -eq 0 ]; then
                    warn "На целевой панели нет Internal Squad. Сначала создайте группу."
                    read -rp "  Нажмите Enter..." < /dev/tty
                    continue
                fi
                echo ""
                echo "  В какую существующую группу добавить новых пользователей?"
                local _i
                for _i in "${!_squad_rows[@]}"; do
                    local _line="${_squad_rows[$_i]}"
                    printf '  %d) %s\n' "$((_i+1))" "${_line#*$'\t'}"
                done
                read -rp "  Номер группы: " _squad_choice < /dev/tty
                [[ "$_squad_choice" =~ ^[0-9]+$ ]] || continue
                [ "$_squad_choice" -ge 1 ] && [ "$_squad_choice" -le "${#_squad_rows[@]}" ] || continue
                _selected_uuid="${_squad_rows[$((_squad_choice-1))]%%$'\t'*}"
                if ! python3 "$_worker" preview --input "$_input" --squad-uuid "$_selected_uuid"; then
                    warn "Предварительная проверка не пройдена"
                    read -rp "  Нажмите Enter..." < /dev/tty
                    continue
                fi
                warn "Будут добавлены только новые пользователи. Существующие записи не изменяются."
                read -rp "  Для подтверждения введите IMPORT: " _answer < /dev/tty
                [ "$_answer" = "IMPORT" ] || { info "Импорт отменён"; continue; }
                python3 "$_worker" import --input "$_input" --squad-uuid "$_selected_uuid" --apply \
                    || warn "Импорт завершился с ошибкой; проверьте вывод выше"
                read -rp "  Нажмите Enter..." < /dev/tty
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}
