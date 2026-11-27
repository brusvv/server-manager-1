#!/usr/bin/env bash
# Import user accounts through the target Remnawave API; never overwrite target DB.
remnawave_users_migrate() {
    header "Перенос пользователей Remnawave"
    local panel_dir="/opt/remnawave"
    [ -f "$panel_dir/docker-compose.yml" ] || { err "Исходная панель не найдена"; return 1; }
    for cmd in docker jq curl; do command -v "$cmd" >/dev/null 2>&1 || { err "Не найдена зависимость: $cmd"; return 1; }; done

    local target_url token
    read -rp "  URL целевой панели (https://panel.example.com): " target_url < /dev/tty
    target_url="${target_url%/}"
    [[ "$target_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { err "Некорректный URL"; return 1; }
    read -rsp "  API token (scopes users:create и internal-squads:list): " token < /dev/tty
    echo
    [ -n "$token" ] || { err "Пустой API token"; return 1; }

    local tmpdir
    tmpdir="$(mktemp -d /tmp/rw-user-migrate.XXXXXX)" || return 1
    chmod 700 "$tmpdir"
    local source_json="$tmpdir/source.json" target_squads="$tmpdir/target-squads.json"
    local response="$tmpdir/response.json" body="$tmpdir/body.json" payloads="$tmpdir/payloads.ndjson"
    trap 'rm -rf "$tmpdir"; unset token' RETURN

    info "Проверяем API целевой панели..."
    local http_code
    http_code=$(curl -sS --connect-timeout 8 --max-time 20 -o "$target_squads" -w '%{http_code}' \
        -H "Authorization: Bearer $token" -H 'Accept: application/json' "$target_url/api/internal-squads") || {
        err "Нет соединения с API целевой панели"; return 1;
    }
    [ "$http_code" = "200" ] || { err "API вернул HTTP $http_code (проверьте URL и scope internal-squads:list)"; return 1; }
    jq -e '.response.internalSquads | type == "array"' "$target_squads" >/dev/null 2>&1 || {
        err "Неожиданный ответ API internal-squads"; return 1;
    }

    info "Экспортируем исходные учётные записи..."
    local sql
    sql="SELECT json_build_object('users', COALESCE((
      SELECT json_agg((to_jsonb(u) || jsonb_build_object('active_squad_names',
        COALESCE((SELECT json_agg(s.name ORDER BY s.name)
          FROM internal_squad_members m JOIN internal_squads s ON s.uuid=m.internal_squad_uuid
          WHERE m.user_id=u.id), '[]'::json))) ORDER BY u.id) FROM users u
    ), '[]'::json))::text;"
    if ! (cd "$panel_dir" && docker compose exec -T remnawave-db psql -X -U postgres -d remnawave -Atqc "$sql") > "$source_json"; then
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
          if ($mapped|length) != ($names|length) then error("target squad missing") else
          {
            username:$u.username, status:$u.status, shortUuid:$u.short_uuid,
            trojanPassword:$u.trojan_password, vlessUuid:$u.vless_uuid, ssPassword:$u.ss_password,
            trafficLimitBytes:($u.traffic_limit_bytes|tonumber? // 0),
            trafficLimitStrategy:$u.traffic_limit_strategy, expireAt:$u.expire_at,
            createdAt:$u.created_at, lastTrafficResetAt:$u.last_traffic_reset_at,
            description:$u.description, tag:$u.tag,
            telegramId:($u.telegram_id|if . == null then null else (tonumber? // .) end),
            email:$u.email, hwidDeviceLimit:($u.hwid_device_limit|tonumber? // 0),
            activeInternalSquads:$mapped
          } | with_entries(select(.value != null)) end
        ' "$source_json" >> "$payloads" 2>/dev/null; then
            warn "Не удалось подготовить $username: проверьте соответствие internal squad по имени"
            failed=1
        fi
    done < <(jq -r '.users[].username' "$source_json")
    if [ "$failed" -ne 0 ]; then err "Проверка прервана до записи: не все squad сопоставлены"; return 1; fi
    [ "$(wc -l < "$payloads" | tr -d ' ')" = "$user_count" ] || { err "Число подготовленных записей не совпало"; return 1; }

    echo ""
    echo "  Будет создано пользователей: $user_count"
    echo "  Internal squad на целевой панели: $squad_count"
    echo "  Переносятся: username, статусы, сроки, UUID/пароли протоколов, лимиты, описание, теги, email/Telegram, HWID limit и squad membership."
    echo ""
    warn "Не переносятся: накопленный трафик, HWID fingerprints, node/subscription history, внешние squad и node IDs."
    warn "Целевые пользователи не перезаписываются. При совпадении уникальных полей API отклонит создание."
    read -rp "  Для запуска введите yes: " confirm < /dev/tty
    [ "$confirm" = "yes" ] || { info "Отменено, изменений нет"; return 0; }

    local created=0 errors=0 line
    while IFS= read -r line; do
        printf '%s\n' "$line" > "$body"
        username=$(jq -r '.username' "$body")
        http_code=$(curl -sS --connect-timeout 8 --max-time 30 -o "$response" -w '%{http_code}' \
            -X POST "$target_url/api/users" -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' -H 'Accept: application/json' --data-binary "@$body") || http_code="000"
        if [[ "$http_code" = "200" || "$http_code" = "201" ]]; then
            created=$((created+1)); ok "Создан: $username"
        else
            errors=$((errors+1)); warn "Ошибка создания $username (HTTP $http_code); подробности ответа скрыты"
        fi
    done < "$payloads"

    echo ""
    echo "  Результат: создано $created из $user_count; ошибок: $errors"
    if [ "$errors" -gt 0 ]; then warn "Частичный перенос. Успешно созданные записи оставлены на целевой панели."; return 1; fi
    ok "Перенос учётных записей завершён"
    info "Проверьте пользователей и подписки на целевой панели."
}
