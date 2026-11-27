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

# Read-only preflight for the related Remnawave tables. No INSERT/UPDATE/DELETE
# is performed here; the target IDs are obtained from read-only API responses.
remnawave_users_related_audit() (
    header "Аудит связанных данных Remnawave (только чтение)"
    local panel_dir="/opt/remnawave"
    [ -f "$panel_dir/docker-compose.yml" ] || { err "Исходная панель не найдена"; return 1; }
    for cmd in docker jq curl; do command -v "$cmd" >/dev/null 2>&1 || { err "Не найдена зависимость: $cmd"; return 1; }; done

    local target_url token
    read -rp "  URL целевой панели (https://panel.example.com): " target_url < /dev/tty
    target_url="${target_url%/}"
    [[ "$target_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { err "Некорректный URL"; return 1; }
    read -rsp "  API token (scopes users:by-username и nodes:list): " token < /dev/tty
    echo
    [ -n "$token" ] || { err "Пустой API token"; return 1; }
    [[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || { err "API token содержит недопустимые символы"; return 1; }

    local tmpdir auth_config source_json nodes_json response
    tmpdir="$(mktemp -d /tmp/rw-related-audit.XXXXXX)" || return 1
    chmod 700 "$tmpdir"
    auth_config="$tmpdir/curl-auth.conf"
    source_json="$tmpdir/source-audit.json"
    nodes_json="$tmpdir/target-nodes.json"
    response="$tmpdir/target-user.json"
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$auth_config"
    chmod 600 "$auth_config"
    unset token
    trap 'rm -rf "$tmpdir"' EXIT

    local pg_user pg_db table_check sql http_code
    pg_user=$(grep -m1 '^POSTGRES_USER=' "$panel_dir/.env" 2>/dev/null | cut -d= -f2- | tr -d "\"'\\r")
    pg_db=$(grep -m1 '^POSTGRES_DB=' "$panel_dir/.env" 2>/dev/null | cut -d= -f2- | tr -d "\"'\\r")
    pg_user="${pg_user:-postgres}"
    pg_db="${pg_db:-postgres}"

    info "Проверяем наличие таблиц в исходной БД..."
    sql="SELECT json_agg(t.table_name ORDER BY t.table_name)::text
         FROM information_schema.tables t
         WHERE t.table_schema='public'
           AND t.table_name IN ('users','nodes','user_traffic','hwid_user_devices','nodes_user_usage_history','user_subscription_request_history');"
    table_check="$(cd "$panel_dir" && docker compose exec -T remnawave-db psql -X -U "$pg_user" -d "$pg_db" -Atqc "$sql")" || {
        err "Не удалось проверить схему исходной БД"; return 1;
    }
    local required_tables
    required_tables='["users","nodes","user_traffic","hwid_user_devices","nodes_user_usage_history","user_subscription_request_history"]'
    if ! jq -e --argjson required "$required_tables" 'type=="array" and ($required - $) == []' <<< "$table_check" >/dev/null 2>&1; then
        err "В исходной БД отсутствует одна или несколько необходимых таблиц."
        info "Обнаружены таблицы: ${table_check:-[]}"
        return 1
    fi

    info "Собираем агрегаты и технические ID из исходной БД (без IP и HWID значений)..."
    sql="SELECT json_build_object(
      'users', COALESCE((SELECT json_agg(json_build_object(
        'id',u.id::text,'username',u.username,'short_uuid',u.short_uuid,
        'vless_uuid',u.vless_uuid::text,'trojan_password',u.trojan_password,'ss_password',u.ss_password
      ) ORDER BY u.id) FROM users u), '[]'::json),
      'nodes', COALESCE((SELECT json_agg(json_build_object(
        'id',n.id::text,'uuid',n.uuid::text,'name',n.name,'address',n.address,'port',n.port
      ) ORDER BY n.id) FROM nodes n), '[]'::json),
      'node_usage_ids', COALESCE((SELECT json_agg(DISTINCT node_id::text ORDER BY node_id::text) FROM nodes_user_usage_history), '[]'::json),
      'last_connected_node_uuids', COALESCE((SELECT json_agg(DISTINCT last_connected_node_uuid ORDER BY last_connected_node_uuid)
        FROM user_traffic WHERE last_connected_node_uuid IS NOT NULL), '[]'::json),
      'stats', json_build_object(
        'user_traffic_rows',(SELECT count(*) FROM user_traffic),
        'user_traffic_used_bytes',(SELECT COALESCE(sum(used_traffic_bytes),0)::text FROM user_traffic),
        'user_traffic_lifetime_bytes',(SELECT COALESCE(sum(lifetime_used_traffic_bytes),0)::text FROM user_traffic),
        'user_traffic_with_last_node',(SELECT count(*) FROM user_traffic WHERE last_connected_node_uuid IS NOT NULL),
        'hwid_rows',(SELECT count(*) FROM hwid_user_devices),
        'hwid_users',(SELECT count(DISTINCT user_id) FROM hwid_user_devices),
        'hwid_rows_with_request_ip',(SELECT count(*) FROM hwid_user_devices WHERE request_ip IS NOT NULL),
        'node_usage_rows',(SELECT count(*) FROM nodes_user_usage_history),
        'node_usage_users',(SELECT count(DISTINCT user_id) FROM nodes_user_usage_history),
        'node_usage_nodes',(SELECT count(DISTINCT node_id) FROM nodes_user_usage_history),
        'node_usage_total_bytes',(SELECT COALESCE(sum(total_bytes),0)::text FROM nodes_user_usage_history),
        'subscription_history_rows',(SELECT count(*) FROM user_subscription_request_history),
        'subscription_history_users',(SELECT count(DISTINCT user_id) FROM user_subscription_request_history),
        'subscription_history_with_request_ip',(SELECT count(*) FROM user_subscription_request_history WHERE request_ip IS NOT NULL),
        'orphan_user_traffic',(SELECT count(*) FROM user_traffic t LEFT JOIN users u ON u.id=t.id WHERE u.id IS NULL),
        'orphan_hwid_users',(SELECT count(*) FROM hwid_user_devices h LEFT JOIN users u ON u.id=h.user_id WHERE u.id IS NULL),
        'orphan_node_usage_users',(SELECT count(*) FROM nodes_user_usage_history h LEFT JOIN users u ON u.id=h.user_id WHERE u.id IS NULL),
        'orphan_node_usage_nodes',(SELECT count(*) FROM nodes_user_usage_history h LEFT JOIN nodes n ON n.id=h.node_id WHERE n.id IS NULL),
        'orphan_last_connected_nodes',(SELECT count(*) FROM user_traffic t LEFT JOIN nodes n ON n.uuid=t.last_connected_node_uuid WHERE t.last_connected_node_uuid IS NOT NULL AND n.uuid IS NULL),
        'orphan_subscription_users',(SELECT count(*) FROM user_subscription_request_history h LEFT JOIN users u ON u.id=h.user_id WHERE u.id IS NULL)
      )
    )::text;"
    if ! (cd "$panel_dir" && docker compose exec -T remnawave-db psql -X -U "$pg_user" -d "$pg_db" -Atqc "$sql") > "$source_json"; then
        err "Не удалось прочитать связанные таблицы"; return 1;
    fi
    jq -e '.users|type=="array"' "$source_json" >/dev/null 2>&1 || { err "Некорректный ответ аудита БД"; return 1; }

    info "Получаем список нод целевой панели (GET /api/nodes)..."
    http_code=$(curl -sS --connect-timeout 8 --max-time 25 -o "$nodes_json" -w '%{http_code}' \
        -K "$auth_config" -H 'Accept: application/json' "$target_url/api/nodes") || {
        err "Нет соединения с API целевой панели"; return 1;
    }
    [ "$http_code" = "200" ] || { err "API нод вернул HTTP $http_code (нужен scope nodes:list)"; return 1; }
    jq -e '.response|type=="array"' "$nodes_json" >/dev/null 2>&1 || { err "Неожиданный формат списка нод"; return 1; }

    local users_total users_mapped users_unmapped user_line username node_total node_mapped node_unmapped node_line
    users_total=$(jq '.users|length' "$source_json")
    users_mapped=0; users_unmapped=0
    while IFS= read -r user_line; do
        username=$(printf '%s' "$user_line" | jq -r '.username')
        http_code=$(curl -sS --connect-timeout 8 --max-time 20 -o "$response" -w '%{http_code}' \
            -K "$auth_config" "$target_url/api/users/by-username/$username") || http_code="000"
        if [ "$http_code" = "200" ] && jq -e --argjson source "$user_line" '
            .response as $target |
            ($target.id|type=="number" and . <= 9007199254740991) and
            ($target.username==$source.username) and
            ($target.shortUuid==$source.short_uuid) and
            ($target.vlessUuid==$source.vless_uuid) and
            ($target.trojanPassword==$source.trojan_password) and
            ($target.ssPassword==$source.ss_password)
        ' "$response" >/dev/null 2>&1; then
            users_mapped=$((users_mapped+1))
        else
            users_unmapped=$((users_unmapped+1))
        fi
    done < <(jq -c '.users[]' "$source_json")

    # Only nodes referenced by either user_traffic or nodes_user_usage_history
    # are required for the related-data phase.
    local referenced_nodes
    if ! referenced_nodes="$(jq -cn --slurpfile src "$source_json" '
      ((($src[0].node_usage_ids) as $ids |
        [$src[0].nodes[] as $node | select($ids | index($node.id)) | $node]) +
       (($src[0].last_connected_node_uuids // []) as $uuids |
        [$src[0].nodes[] as $node | select($uuids | index($node.uuid)) | $node]))
      | unique_by(.id)
    ')"; then
        err "Не удалось вычислить список исходных нод для сопоставления"; return 1;
    fi
    node_total=$(jq 'length' <<< "$referenced_nodes")
    node_mapped=0; node_unmapped=0
    while IFS= read -r node_line; do
        local node_matches
        node_matches=$(jq --argjson source "$node_line" '
          [.response[] | select(.name==$source.name and .address==$source.address and .port==$source.port)]
        ' "$nodes_json")
        if [ "$(jq 'length' <<< "$node_matches")" = "1" ] && \
           [ "$(jq -r '.[0].id|type' <<< "$node_matches")" = "number" ] && \
           [ "$(jq -r '.[0].id <= 9007199254740991' <<< "$node_matches")" = "true" ] && \
           [ -n "$(jq -r '.[0].uuid // empty' <<< "$node_matches")" ]; then
            node_mapped=$((node_mapped+1))
        else
            node_unmapped=$((node_unmapped+1))
        fi
    done < <(jq -c '.[]' <<< "$referenced_nodes")

    echo ""
    echo "  Исходные пользователи: $users_total; точное сопоставление с целевой API: $users_mapped; не сопоставлено: $users_unmapped"
    echo "  Ноды, используемые связанными таблицами: $node_total; точное сопоставление name+address+port: $node_mapped; не сопоставлено: $node_unmapped"
    echo ""
    echo "  Статистика исходной БД:"
    jq -r '.stats | to_entries[] | "    \(.key): \(.value)"' "$source_json"
    echo ""
    warn "IP-адреса и HWID не выводились; учитывались только количества строк с request_ip."
    warn "Целевая БД не изменялась. API-сверка не проверяет конфликты существующих HWID/истории на целевой стороне."
    warn "Текущий API-аудит не проверяет, совпадают ли накопленные счётчики на целевой панели."
    if [ "$users_unmapped" -gt 0 ] || [ "$node_unmapped" -gt 0 ] || \
       [ "$(jq '[.stats.orphan_user_traffic,.stats.orphan_hwid_users,.stats.orphan_node_usage_users,.stats.orphan_node_usage_nodes,.stats.orphan_last_connected_nodes,.stats.orphan_subscription_users] | add' "$source_json")" -gt 0 ]; then
        err "Аудит завершён с блокирующими несоответствиями. Перенос связанных данных пока невозможен."
        return 1
    fi
    ok "Базовое сопоставление пользователей и используемых нод прошло. Это ещё не разрешение на запись."
)

