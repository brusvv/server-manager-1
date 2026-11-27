#!/usr/bin/env bash
# Import user accounts through the target Remnawave API; never overwrite target DB.
remnawave_users_migrate() (
    header "Перенос пользователей Remnawave"
    local panel_dir="/opt/remnawave"
    [ -f "$panel_dir/docker-compose.yml" ] || { err "Исходная панель не найдена"; return 1; }
    for cmd in docker jq curl; do command -v "$cmd" >/dev/null 2>&1 || { err "Не найдена зависимость: $cmd"; return 1; }; done

    local target_url token
    read -rp "  URL целевой панели (https://panel.example.com): " target_url < /dev/tty
    target_url="${target_url%/}"
    [[ "$target_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { err "Некорректный URL"; return 1; }
    read -rsp "  API token (scopes users:create, users:by-username, users:by-short-uuid и internal-squads:list): " token < /dev/tty
    echo
    [ -n "$token" ] || { err "Пустой API token"; return 1; }
    # The token is written into a curl config file. Restrict it to the
    # bearer-token alphabet so quotes/control characters cannot inject config.
    [[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || {
        err "API token содержит недопустимые символы"; return 1;
    }

    local tmpdir
    tmpdir="$(mktemp -d /tmp/rw-user-migrate.XXXXXX)" || return 1
    chmod 700 "$tmpdir"
    local source_json="$tmpdir/source.json" target_squads="$tmpdir/target-squads.json"
    local response="$tmpdir/response.json" body="$tmpdir/body.json" payloads="$tmpdir/payloads.ndjson"
    local target_matches="$tmpdir/target-matches.ndjson"
    local auth_config="$tmpdir/curl-auth.conf"
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$auth_config"
    chmod 600 "$auth_config"
    unset token
    trap 'rm -rf "$tmpdir"' EXIT

    info "Проверяем API целевой панели..."
    local http_code
    http_code=$(curl -sS --connect-timeout 8 --max-time 20 -o "$target_squads" -w '%{http_code}' \
        -K "$auth_config" -H 'Accept: application/json' "$target_url/api/internal-squads") || {
        err "Нет соединения с API целевой панели"; return 1;
    }
    [ "$http_code" = "200" ] || { err "API вернул HTTP $http_code (проверьте URL и scopes internal-squads:list)"; return 1; }
    jq -e '.response.internalSquads | type == "array"' "$target_squads" >/dev/null 2>&1 || {
        err "Неожиданный ответ API internal-squads"; return 1;
    }

    info "Экспортируем исходные учётные записи..."
    local sql pg_user pg_db
    pg_user=$(grep -m1 '^POSTGRES_USER=' "$panel_dir/.env" 2>/dev/null | cut -d= -f2- | tr -d "\"'\\r")
    pg_db=$(grep -m1 '^POSTGRES_DB=' "$panel_dir/.env" 2>/dev/null | cut -d= -f2- | tr -d "\"'\\r")
    pg_user="${pg_user:-postgres}"
    pg_db="${pg_db:-postgres}"
    sql="SELECT json_build_object('users', COALESCE((
      SELECT json_agg((to_jsonb(u) || jsonb_build_object('active_squad_names',
        COALESCE((SELECT json_agg(s.name ORDER BY s.name)
          FROM internal_squad_members m JOIN internal_squads s ON s.uuid=m.internal_squad_uuid
          WHERE m.user_id=u.id), '[]'::json))) ORDER BY u.id) FROM users u
    ), '[]'::json))::text;"
    if ! (cd "$panel_dir" && docker compose exec -T remnawave-db psql -X -U "$pg_user" -d "$pg_db" -Atqc "$sql") > "$source_json"; then
        err "Не удалось экспортировать пользователей из БД"; return 1;
    fi
    jq -e '.users | type == "array"' "$source_json" >/dev/null 2>&1 || { err "Некорректный экспорт БД"; return 1; }
    local user_count squad_count
    user_count=$(jq '.users | length' "$source_json")
    squad_count=$(jq '.response.internalSquads | length' "$target_squads" 2>/dev/null || echo 0)
    [ "$user_count" -gt 0 ] || { warn "В исходной панели нет пользователей"; return 0; }

    # Prepare and validate every request before the first write.
    : > "$payloads"
    local failed=0 username
    while IFS= read -r username; do
        if ! jq -c --arg username "$username" --slurpfile target "$target_squads" '
          .users[] | select(.username == $username) as $u |
          ($u.active_squad_names // []) as $names |
          [ $names[] as $n | ($target[0].response.internalSquads[] | select(.name == $n) | .uuid) ] as $mapped |
          if ($u.username|test("^[A-Za-z0-9_-]{3,36}$")|not) then error("invalid username")
          elif (($u.tag // "") != "" and (($u.tag|length)>16 or ($u.tag|test("^[A-Z0-9_]+$")|not))) then error("invalid tag")
          elif ($u.id|type) != "number" then error("missing source user id")
          elif $u.expire_at == null then error("missing expiration")
          elif ($u.short_uuid == null or $u.short_uuid == "") then error("missing short UUID")
          elif (($u.traffic_limit_bytes|tonumber? // 0) > 9007199254740991) then error("traffic limit exceeds JS safe integer")
          elif ($u.telegram_id != null and (($u.telegram_id|tonumber? // 0) > 9007199254740991)) then error("telegram id exceeds JS safe integer")
          elif ($u.trojan_password != null and (($u.trojan_password|length)<8 or ($u.trojan_password|length)>32)) then error("invalid trojan password")
          elif ($u.ss_password != null and (($u.ss_password|length)<8 or ($u.ss_password|length)>32)) then error("invalid shadowsocks password")
          elif ($mapped|length) != ($names|length) then error("target squad missing") else
          {
            sourceUserId:$u.id,
            username:$u.username, status:$u.status, shortUuid:$u.short_uuid,
            trojanPassword:$u.trojan_password, vlessUuid:$u.vless_uuid, ssPassword:$u.ss_password,
            trafficLimitBytes:($u.traffic_limit_bytes|tonumber? // 0),
            trafficLimitStrategy:$u.traffic_limit_strategy, expireAt:$u.expire_at,
            createdAt:$u.created_at, lastTrafficResetAt:$u.last_traffic_reset_at,
            description:$u.description, tag:($u.tag | if . == "" then null else . end),
            telegramId:($u.telegram_id|if . == null then null else (tonumber? // .) end),
            email:$u.email, hwidDeviceLimit:($u.hwid_device_limit|tonumber? // 0),
            activeInternalSquads:$mapped
          } | with_entries(select(.value != null)) end
        ' "$source_json" >> "$payloads" 2>/dev/null; then
            warn "Не удалось подготовить $username: проверьте squad mapping и ограничения полей API (username/tag/password)"
            failed=1
        fi
    done < <(jq -r '.users[].username' "$source_json")
    if [ "$failed" -ne 0 ]; then err "Проверка прервана до записи: не все squad сопоставлены"; return 1; fi
    [ "$(wc -l < "$payloads" | tr -d ' ')" = "$user_count" ] || { err "Число подготовленных записей не совпало"; return 1; }

    # Reject duplicate source identifiers before querying or writing to the target.
    local duplicate_key duplicates duplicate_count
    for duplicate_key in username shortUuid vlessUuid; do
        duplicates=$(jq -s -r --arg key "$duplicate_key" '
          [.[] | select(.[$key] != null and .[$key] != "")] |
          group_by(.[$key]) | map(select(length > 1) | .[0][$key]) | .[]
        ' "$payloads")
        if [ -n "$duplicates" ]; then
            duplicate_count=$(printf '%s\n' "$duplicates" | wc -l | tr -d ' ')
            err "В исходных данных найдены дубликаты $duplicate_key (групп: $duplicate_count)"
            err "Значения идентификаторов не выводятся, чтобы не раскрывать credentials"
            err "Перенос остановлен до записи на целевую панель"
            return 1
        fi
    done

    # Reconcile existing target users before writing. Exact protocol identifiers
    # are required; username-only matches are never treated as migrated users.
    info "Проверяем пользователей на целевой панели и восстанавливаем ID-сопоставления..."
    : > "$target_matches"
    local value check_code line source_id target_id
    while IFS= read -r line; do
        value=$(printf '%s' "$line" | jq -r '.username')
        check_code=$(curl -sS --connect-timeout 8 --max-time 20 -o "$response" -w '%{http_code}' \
            -K "$auth_config" "$target_url/api/users/by-username/$value") || check_code="000"
        if [ "$check_code" = "200" ]; then
            if ! jq -e --argjson source "$line" '
                .response as $target |
                ($target.username == $source.username) and
                ($target.shortUuid == $source.shortUuid) and
                ($target.vlessUuid == $source.vlessUuid) and
                ($target.trojanPassword == $source.trojanPassword) and
                ($target.ssPassword == $source.ssPassword)
            ' "$response" >/dev/null 2>&1; then
                err "На целевой панели найден $value, но его идентификаторы не совпадают с исходными. Автоматическое продолжение запрещено."
                return 1
            fi
            source_id=$(printf '%s' "$line" | jq -r '.sourceUserId')
            target_id=$(jq -er '.response.id | select(type == "number")' "$response" 2>/dev/null) || {
                err "Целевой API не вернул числовой ID для $value"; return 1;
            }
            jq -cn --argjson source_user_id "$source_id" --argjson target_user_id "$target_id" \
                --arg username "$value" \
                '{source_user_id:$source_user_id,target_user_id:$target_user_id,username:$username}' >> "$target_matches"
        elif [ "$check_code" = "404" ]; then
            value=$(printf '%s' "$line" | jq -r '.shortUuid | @uri')
            check_code=$(curl -sS --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' \
                -K "$auth_config" "$target_url/api/users/by-short-uuid/$value") || check_code="000"
            if [ "$check_code" != "404" ]; then
                err "Short UUID исходного пользователя уже занят или проверка недоступна (HTTP $check_code). Запись не начата."
                return 1
            fi
        else
            err "Не удалось проверить пользователя на целевой панели (HTTP $check_code). Запись не начата."
            return 1
        fi
    done < "$payloads"

    local target_host journal_dir journal
    target_host="${target_url#https://}"
    target_host="${target_host//[^A-Za-z0-9._-]/_}"
    journal_dir="/var/lib/server-manager/migrations"
    if ! install -d -m 700 "$journal_dir"; then
        err "Не удалось создать каталог журнала миграции"; return 1
    fi
    journal="$journal_dir/remnawave-users-${target_host}.jsonl"
    if ! touch "$journal" || ! chmod 600 "$journal"; then
        err "Не удалось подготовить журнал миграции"; return 1
    fi

    echo ""
    echo "  Будет создано пользователей: $user_count"
    echo "  Internal squad на целевой панели: $squad_count"
    echo "  Переносятся: username, статусы, сроки, UUID/пароли протоколов, лимиты, описание, теги, email/Telegram, HWID limit и squad membership."
    echo ""
    warn "Не переносятся: накопленный трафик, HWID fingerprints, node/subscription history, внешние squad и node IDs."
    info "Журнал операций: $journal"
    echo ""
    echo "  Режим работы:"
    echo "    1) Dry-run — только проверки и отчёт, без создания пользователей"
    echo "    2) Apply   — создать пользователей на целевой панели"
    local mode
    read -rp "  Выберите режим [1/2]: " mode < /dev/tty
    case "$mode" in
        1)
            ok "Dry-run завершён: все $user_count пользователей прошли предварительную проверку"
            info "Изменений на целевой панели не выполнено; новые записи в журнал не добавлялись."
            return 0
            ;;
        2) ;;
        *) warn "Неизвестный режим. Изменений нет."; return 1 ;;
    esac

    warn "Целевые пользователи не перезаписываются. При совпадении уникальных полей API отклонит создание."
    read -rp "  Для запуска введите yes: " confirm < /dev/tty
    [ "$confirm" = "yes" ] || { info "Отменено, изменений нет"; return 0; }

    local created=0 skipped=0 errors=0 journal_errors=0 timestamp result_status
    while IFS= read -r line; do
        printf '%s\n' "$line" | jq 'del(.sourceUserId)' > "$body"
        username=$(jq -r '.username' "$body")
        local source_user_id target_user_id target_user_id_json matched
        source_user_id=$(printf '%s' "$line" | jq -r '.sourceUserId')
        timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        matched=$(jq -s --argjson source_id "$source_user_id" '[.[] | select(.source_user_id == $source_id)] | first // empty' "$target_matches")
        if [ -n "$matched" ]; then
            target_user_id=$(printf '%s' "$matched" | jq -r '.target_user_id')
            skipped=$((skipped+1)); result_status="RECONCILED"; http_code="200"
            ok "Уже существует и проверен: $username (source ID $source_user_id -> target ID $target_user_id)"
            target_user_id_json="$target_user_id"
            if ! jq -cn --arg timestamp "$timestamp" --arg username "$username" \
                --arg status "$result_status" --arg http_code "$http_code" \
                --argjson source_user_id "$source_user_id" --argjson target_user_id "$target_user_id_json" \
                '{timestamp:$timestamp,username:$username,source_user_id:$source_user_id,target_user_id:$target_user_id,status:$status,http_code:$http_code}' >> "$journal"; then
                journal_errors=$((journal_errors+1)); warn "Не удалось записать сверенное соответствие в журнал; дальнейшая обработка остановлена"; break
            fi
            continue
        fi
        http_code=$(curl -sS --connect-timeout 8 --max-time 30 -o "$response" -w '%{http_code}' \
            -X POST "$target_url/api/users" -K "$auth_config" \
            -H 'Content-Type: application/json' -H 'Accept: application/json' --data-binary "@$body") || http_code="000"
        target_user_id=""
        if [[ "$http_code" = "200" || "$http_code" = "201" ]]; then
            target_user_id=$(jq -er '.response.id | select(type == "number")' "$response" 2>/dev/null) || target_user_id=""
            if [ -n "$target_user_id" ]; then
                created=$((created+1)); result_status="CREATED"; ok "Создан: $username (source ID $source_user_id -> target ID $target_user_id)"
            else
                errors=$((errors+1)); result_status="CREATED_UNMAPPED"
                warn "API сообщил об успешном создании $username, но response.id отсутствует; остановка для ручной сверки"
            fi
        else
            errors=$((errors+1)); result_status="FAILED"; warn "Ошибка создания $username (HTTP $http_code); подробности ответа скрыты"
        fi
        target_user_id_json="${target_user_id:-null}"
        if ! jq -cn --arg timestamp "$timestamp" --arg username "$username" \
            --arg status "$result_status" --arg http_code "$http_code" \
            --argjson source_user_id "$source_user_id" \
            --argjson target_user_id "$target_user_id_json" \
            '{timestamp:$timestamp,username:$username,source_user_id:$source_user_id,target_user_id:$target_user_id,status:$status,http_code:$http_code}' >> "$journal"; then
            journal_errors=$((journal_errors+1))
            warn "Не удалось записать результат $username в журнал; дальнейшее создание остановлено"
            break
        fi
        if [ "$result_status" = "CREATED_UNMAPPED" ]; then
            warn "Дальнейшие запросы остановлены: требуется сверить созданную запись на целевой панели"
            break
        fi
    done < "$payloads"

    echo ""
    echo "  Результат: создано $created; уже существовало и сверено: $skipped; ошибок API: $errors; ошибок журнала: $journal_errors"
    info "Журнал операций сохранён: $journal"
    if [ "$errors" -gt 0 ] || [ "$journal_errors" -gt 0 ]; then warn "Частичный перенос. Успешно созданные записи оставлены на целевой панели."; return 1; fi
    ok "Перенос учётных записей завершён"
    info "Проверьте пользователей и подписки на целевой панели."
)
