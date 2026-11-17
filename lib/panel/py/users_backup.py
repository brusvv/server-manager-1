#!/usr/bin/env python3
"""Remnawave Users-only backup/restore.

One-shot CLI. Requires Python 3.10+, Docker Compose, and psql in the
remnawave-db container. Export refuses overwrite. Import is add-only,
skips username/short_uuid/vless_uuid conflicts, remaps numeric IDs, and
commits all inserted user-related rows in one PostgreSQL transaction.
"""
from __future__ import annotations
import argparse, hashlib, json, os, re, secrets, subprocess, sys, zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

FORMAT = "server-manager.remnawave.users-only"
FORMAT_VERSION = 1
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
PROJECT_DIR = Path("/opt/remnawave")
DB_CONTAINER = "remnawave-db"
USER_COLUMNS = (
    "short_uuid", "username", "status", "traffic_limit_bytes",
    "traffic_limit_strategy", "expire_at", "last_traffic_reset_at",
    "sub_revoked_at", "trojan_password", "vless_uuid", "ss_password",
    "description", "tag", "telegram_id", "email", "hwid_device_limit",
    "last_triggered_threshold", "created_at", "updated_at",
)
REQUIRED_SCHEMA = {
    "users": set(USER_COLUMNS) | {"id", "external_squad_uuid"},
    "user_traffic": {"id", "used_traffic_bytes", "lifetime_used_traffic_bytes",
                     "online_at", "last_connected_node_uuid", "first_connected_at"},
    "user_meta": {"user_id", "metadata"},
    "hwid_user_devices": {"hwid", "user_id", "platform", "os_version",
                          "device_model", "user_agent", "request_ip",
                          "created_at", "updated_at"},
    "internal_squads": {"uuid", "name", "view_position"},
    "internal_squad_members": {"internal_squad_uuid", "user_id"},
}


class UsersBackupError(Exception):
    pass


def _env_value(path: Path, key: str, default: str) -> str:
    if not path.is_file():
        return default
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        if name.strip() == key:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            return value
    return default


def _db_command() -> list[str]:
    if not PROJECT_DIR.is_dir() or not (PROJECT_DIR / "docker-compose.yml").is_file():
        raise UsersBackupError(f"Не найден Compose-проект панели: {PROJECT_DIR}")
    user = _env_value(PROJECT_DIR / ".env", "POSTGRES_USER", "postgres")
    database = _env_value(PROJECT_DIR / ".env", "POSTGRES_DB", "postgres")
    return ["docker", "compose", "exec", "-T", DB_CONTAINER, "psql", "-X",
            "-U", user, "-d", database, "-A", "-t", "-v", "ON_ERROR_STOP=1"]


def psql(sql: str) -> str:
    try:
        proc = subprocess.run(_db_command(), cwd=PROJECT_DIR, input=sql, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except FileNotFoundError as exc:
        raise UsersBackupError("Не найдена команда docker") from exc
    if proc.returncode:
        raise UsersBackupError((proc.stderr.strip() or "Ошибка PostgreSQL")[-5000:])
    return proc.stdout.strip()


def _sql_json_literal(value: Any) -> str:
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    tag = "users_payload_" + secrets.token_hex(12)
    while ("$" + tag + "$") in raw:
        tag = "users_payload_" + secrets.token_hex(12)
    return "$" + tag + "$" + raw + "$" + tag + "$::jsonb"


def schema_check() -> None:
    sql = """
SELECT COALESCE(jsonb_object_agg(table_name, columns), '{}'::jsonb)::text
FROM (
 SELECT table_name, jsonb_agg(column_name ORDER BY column_name) AS columns
 FROM information_schema.columns
 WHERE table_schema='public'
 AND table_name=ANY(ARRAY['users','user_traffic','user_meta','hwid_user_devices',
                          'internal_squads','internal_squad_members'])
 GROUP BY table_name
) s;
"""
    try:
        found = json.loads(psql(sql) or "{}")
    except json.JSONDecodeError as exc:
        raise UsersBackupError("Не удалось прочитать схему PostgreSQL") from exc
    missing = []
    for table, required in REQUIRED_SCHEMA.items():
        present = set(found.get(table, []))
        if not present:
            missing.append(f"{table} (таблица отсутствует)")
        elif required - present:
            missing.append(f"{table}: {', '.join(sorted(required - present))}")
    if missing:
        raise UsersBackupError("Схема Remnawave не поддерживается:\n  " + "\n  ".join(missing))


EXPORT_SQL = r"""
SELECT jsonb_build_object(
 'format','server-manager.remnawave.users-only',
 'formatVersion',1,
 'exportedAt',to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
 'users',COALESCE((
  SELECT jsonb_agg(jsonb_build_object(
   'sourceId',u.id::text,
   'user',to_jsonb(u),
   'traffic',(SELECT to_jsonb(t) FROM public.user_traffic t WHERE t.id=u.id),
   'meta',(SELECT to_jsonb(m) FROM public.user_meta m WHERE m.user_id=u.id),
   'devices',COALESCE((
    SELECT jsonb_agg(to_jsonb(d) ORDER BY d.created_at,d.hwid)
    FROM public.hwid_user_devices d WHERE d.user_id=u.id
   ),'[]'::jsonb)
  ) ORDER BY u.id)
  FROM public.users u
 ),'[]'::jsonb)
)::text;
"""


def validate_users(users: list[Any]) -> None:
    seen = {"username": set(), "short_uuid": set(), "vless_uuid": set()}
    required = ("short_uuid", "username", "status", "expire_at",
                "trojan_password", "vless_uuid", "ss_password")
    for index, item in enumerate(users):
        if not isinstance(item, dict) or not isinstance(item.get("user"), dict):
            raise UsersBackupError(f"Неверный формат пользователя #{index + 1}")
        user = item["user"]
        for field in required:
            if user.get(field) in (None, ""):
                raise UsersBackupError(f"У пользователя #{index + 1} отсутствует {field}")
        values = {"username": str(user["username"]),
                  "short_uuid": str(user["short_uuid"]),
                  "vless_uuid": str(user["vless_uuid"]).lower()}
        if not re.fullmatch(r"[0-9a-f-]{36}", values["vless_uuid"]):
            raise UsersBackupError(f"Некорректный VLESS UUID у {values['username']}")
        for field, value in values.items():
            if value in seen[field]:
                raise UsersBackupError(f"Дубликат {field} внутри архива: {value}")
            seen[field].add(value)
        if not isinstance(item.get("devices", []), list):
            raise UsersBackupError(f"Некорректный список HWID у {values['username']}")


def load_archive(path: Path) -> dict[str, Any]:
    path = path.expanduser()
    if not path.is_file():
        raise UsersBackupError(f"Архив не найден: {path}")
    if path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise UsersBackupError("Размер архива превышает 512 MiB")
    try:
        with zipfile.ZipFile(path) as zf:
            if set(zf.namelist()) != {"manifest.json", "users.json"}:
                raise UsersBackupError("Ожидаются только manifest.json и users.json")
            bad = zf.testzip()
            if bad:
                raise UsersBackupError(f"Повреждён файл архива: {bad}")
            manifest = json.loads(zf.read("manifest.json"))
            body = zf.read("users.json")
    except (zipfile.BadZipFile, KeyError, json.JSONDecodeError) as exc:
        raise UsersBackupError(f"Не удалось прочитать архив: {exc}") from exc
    if not isinstance(manifest, dict):
        raise UsersBackupError("manifest.json должен содержать JSON-объект")
    if manifest.get("format") != FORMAT or manifest.get("formatVersion") != FORMAT_VERSION:
        raise UsersBackupError("Неизвестный формат или версия Users-only архива")
    digest = hashlib.sha256(body).hexdigest()
    if not secrets.compare_digest(digest, str(manifest.get("payloadSha256", ""))):
        raise UsersBackupError("SHA256 users.json не совпадает")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise UsersBackupError("users.json содержит некорректный JSON") from exc
    if not isinstance(payload, dict):
        raise UsersBackupError("users.json должен содержать JSON-объект")
    users = payload.get("users")
    if payload.get("format") != FORMAT or payload.get("formatVersion") != FORMAT_VERSION:
        raise UsersBackupError("Внутренняя версия users.json не совпадает с manifest")
    if not isinstance(users, list) or len(users) != int(manifest.get("usersCount", -1)):
        raise UsersBackupError("Количество пользователей не совпадает с manifest")
    validate_users(users)
    return {"manifest": manifest, "payload": payload}


def write_archive(output: Path) -> None:
    schema_check()
    try:
        payload = json.loads(psql(EXPORT_SQL))
    except json.JSONDecodeError as exc:
        raise UsersBackupError("PostgreSQL вернул некорректный JSON") from exc
    users = payload.get("users")
    if not isinstance(users, list):
        raise UsersBackupError("Экспорт не содержит users")
    validate_users(users)
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    manifest = {
        "format": FORMAT, "formatVersion": FORMAT_VERSION,
        "createdAtUtc": datetime.now(timezone.utc).isoformat(),
        "usersCount": len(users), "payloadSha256": hashlib.sha256(body).hexdigest(),
        "included": ["users", "user_traffic totals", "user_meta", "hwid_user_devices"],
        "excluded": ["nodes/config profiles/inbounds/hosts", "API tokens/keys",
                     "squad definitions", "node-specific history/reports",
                     "subscription request history"],
    }
    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if output.exists():
        raise UsersBackupError(f"Файл уже существует, перезапись запрещена: {output}")
    tmp = output.with_name(output.name + "." + secrets.token_hex(6) + ".tmp")
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            zf.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
            zf.writestr("users.json", body)
        os.chmod(tmp, 0o600)
        load_archive(tmp)
        os.replace(tmp, output)
        os.chmod(output, 0o600)
    finally:
        if tmp.exists():
            tmp.unlink()
    print(f"Архив создан: {output}")
    print(f"Пользователей: {len(users)}")
    print(f"SHA256 users.json: {manifest['payloadSha256']}")
    print("Архив содержит UUID и пароли пользователей — храните его конфиденциально.")


def _payload_sql(payload: dict[str, Any]) -> str:
    literal = _sql_json_literal(payload)
    return f"""
WITH p AS (SELECT {literal} AS doc),
src AS (
 SELECT e.item->'user' AS u FROM p
 CROSS JOIN LATERAL jsonb_array_elements(p.doc->'users') AS e(item)
),
conflicts AS (
 SELECT s.u->>'username' AS username,
 array_remove(ARRAY[
  CASE WHEN EXISTS(SELECT 1 FROM public.users x WHERE x.username=s.u->>'username') THEN 'username' END,
  CASE WHEN EXISTS(SELECT 1 FROM public.users x WHERE x.short_uuid=s.u->>'short_uuid') THEN 'short_uuid' END,
  CASE WHEN EXISTS(SELECT 1 FROM public.users x WHERE x.vless_uuid::text=lower(s.u->>'vless_uuid')) THEN 'vless_uuid' END
 ],NULL) AS reasons
 FROM src s
)
SELECT jsonb_build_object(
 'sourceCount',(SELECT count(*) FROM src),
 'conflicts',COALESCE((SELECT jsonb_agg(jsonb_build_object('username',username,'reasons',reasons) ORDER BY username)
                       FROM conflicts WHERE cardinality(reasons)>0),'[]'::jsonb),
 'existingSquads',COALESCE((SELECT jsonb_agg(jsonb_build_object('uuid',uuid,'name',name) ORDER BY view_position,name)
                            FROM public.internal_squads),'[]'::jsonb)
)::text;
"""


def preflight(payload: dict[str, Any]) -> dict[str, Any]:
    schema_check()
    try:
        result = json.loads(psql(_payload_sql(payload)))
    except json.JSONDecodeError as exc:
        raise UsersBackupError("Не удалось разобрать предварительную проверку") from exc
    result["eligibleCount"] = int(result.get("sourceCount", 0)) - len(result.get("conflicts", []))
    return result


def build_import_sql(payload: dict[str, Any], squad_uuid: str) -> str:
    literal = _sql_json_literal(payload)
    squad = "'" + squad_uuid.replace("'", "''") + "'::uuid"
    return f"""
BEGIN;
CREATE TEMP TABLE _users_payload(doc jsonb) ON COMMIT DROP;
INSERT INTO _users_payload VALUES ({literal});
CREATE TEMP TABLE _users_source ON COMMIT DROP AS
SELECT (e.item->>'sourceId')::bigint AS source_id,
       e.item->'user' AS user_data, e.item->'traffic' AS traffic_data,
       e.item->'meta' AS meta_data, COALESCE(e.item->'devices','[]'::jsonb) AS devices
FROM _users_payload p
CROSS JOIN LATERAL jsonb_array_elements(p.doc->'users') AS e(item);
CREATE TEMP TABLE _users_map(
 source_id bigint PRIMARY KEY, target_id bigint NOT NULL UNIQUE, username text NOT NULL
) ON COMMIT DROP;
DO $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.internal_squads WHERE uuid={squad}) THEN
  RAISE EXCEPTION 'Target Internal Squad no longer exists; import cancelled';
 END IF;
END $$;
WITH inserted AS (
 INSERT INTO public.users(
  short_uuid,username,status,traffic_limit_bytes,traffic_limit_strategy,
  expire_at,last_traffic_reset_at,sub_revoked_at,trojan_password,vless_uuid,
  ss_password,description,tag,telegram_id,email,hwid_device_limit,
  external_squad_uuid,last_triggered_threshold,created_at,updated_at
 )
 SELECT u.short_uuid,u.username,COALESCE(u.status,'ACTIVE'),
        COALESCE(u.traffic_limit_bytes,0),COALESCE(u.traffic_limit_strategy,'NO_RESET'),
        u.expire_at,u.last_traffic_reset_at,u.sub_revoked_at,u.trojan_password,
        u.vless_uuid,u.ss_password,u.description,u.tag,u.telegram_id,u.email,
        u.hwid_device_limit,NULL,COALESCE(u.last_triggered_threshold,0),
        COALESCE(u.created_at,now()),COALESCE(u.updated_at,now())
 FROM _users_source s
 CROSS JOIN LATERAL jsonb_to_record(s.user_data) AS u(
  short_uuid text,username text,status varchar(10),traffic_limit_bytes bigint,
  traffic_limit_strategy text,expire_at timestamp,last_traffic_reset_at timestamp,
  sub_revoked_at timestamp,trojan_password text,vless_uuid uuid,ss_password text,
  description text,tag text,telegram_id bigint,email text,hwid_device_limit integer,
  last_triggered_threshold integer,created_at timestamp,updated_at timestamp
 )
 WHERE NOT EXISTS (
   SELECT 1 FROM public.users existing
   WHERE existing.username = u.username
      OR existing.short_uuid = u.short_uuid
      OR existing.vless_uuid = u.vless_uuid
 )
 ON CONFLICT DO NOTHING
 RETURNING id,username
)
INSERT INTO _users_map(source_id,target_id,username)
SELECT s.source_id,i.id,i.username FROM inserted i
JOIN _users_source s ON s.user_data->>'username'=i.username;

INSERT INTO public.user_traffic(
 id,used_traffic_bytes,lifetime_used_traffic_bytes,online_at,last_connected_node_uuid,first_connected_at
)
SELECT m.target_id,COALESCE(t.used_traffic_bytes,0),
       COALESCE(t.lifetime_used_traffic_bytes,0),NULL,NULL,t.first_connected_at
FROM _users_map m JOIN _users_source s ON s.source_id=m.source_id
LEFT JOIN LATERAL jsonb_to_record(s.traffic_data) AS t(
 used_traffic_bytes bigint,lifetime_used_traffic_bytes bigint,first_connected_at timestamp
) ON TRUE
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.user_meta(user_id,metadata)
SELECT m.target_id,s.meta_data->'metadata'
FROM _users_map m JOIN _users_source s ON s.source_id=m.source_id
WHERE s.meta_data IS NOT NULL AND s.meta_data ? 'metadata'
ON CONFLICT(user_id) DO NOTHING;

INSERT INTO public.hwid_user_devices(
 hwid,user_id,platform,os_version,device_model,user_agent,request_ip,created_at,updated_at
)
SELECT d.hwid,m.target_id,d.platform,d.os_version,d.device_model,d.user_agent,d.request_ip,
       COALESCE(d.created_at,now()),COALESCE(d.updated_at,now())
FROM _users_map m JOIN _users_source s ON s.source_id=m.source_id
CROSS JOIN LATERAL jsonb_to_recordset(s.devices) AS d(
 hwid varchar(64),platform text,os_version text,device_model text,user_agent text,
 request_ip text,created_at timestamp,updated_at timestamp
)
ON CONFLICT(hwid,user_id) DO NOTHING;

INSERT INTO public.internal_squad_members(internal_squad_uuid,user_id)
SELECT {squad},target_id FROM _users_map ON CONFLICT DO NOTHING;

SELECT jsonb_build_object(
 'insertedUsers',(SELECT count(*) FROM _users_map),
 'trafficRows',(SELECT count(*) FROM public.user_traffic t JOIN _users_map m ON m.target_id=t.id),
 'metadataRows',(SELECT count(*) FROM public.user_meta t JOIN _users_map m ON m.target_id=t.user_id),
 'deviceRows',(SELECT count(*) FROM public.hwid_user_devices t JOIN _users_map m ON m.target_id=t.user_id),
 'squadMemberships',(SELECT count(*) FROM public.internal_squad_members t JOIN _users_map m ON m.target_id=t.user_id WHERE t.internal_squad_uuid={squad})
)::text;
COMMIT;
"""


def list_squads() -> None:
    schema_check()
    print(psql("SELECT uuid::text || E'\\t' || name FROM public.internal_squads ORDER BY view_position,name;"))


def show_preview(path: Path, squad_uuid: str | None) -> None:
    data = load_archive(path)
    result = preflight(data["payload"])
    print(f"Пользователей в архиве: {result['sourceCount']}")
    print(f"Новых к добавлению: {result['eligibleCount']}")
    print(f"Конфликтов (не перезаписываются): {len(result['conflicts'])}")
    for item in result["conflicts"][:50]:
        print(f"  - {item['username']}: {', '.join(item['reasons'])}")
    if len(result["conflicts"]) > 50:
        print(f"  ... ещё {len(result['conflicts']) - 50}")
    squads = result.get("existingSquads", [])
    if squad_uuid:
        selected = next((s for s in squads if s["uuid"] == squad_uuid), None)
        if not selected:
            raise UsersBackupError("Выбранная целевая Internal Squad не найдена")
        print(f"Целевая группа: {selected['name']}")
    else:
        print("Доступные Internal Squads:")
        for squad in squads:
            print(f"  {squad['uuid']}  {squad['name']}")
    external = sum(1 for x in data["payload"]["users"] if x["user"].get("external_squad_uuid"))
    if external:
        print(f"Примечание: {external} пользователей имеют source External Squad; эта связь не переносится.")
    print("Режим add-only: существующие записи не меняются.")


def import_archive(path: Path, squad_uuid: str, apply: bool) -> None:
    if not apply:
        raise UsersBackupError("Для записи требуется --apply")
    data = load_archive(path)
    result = preflight(data["payload"])
    if not any(s["uuid"] == squad_uuid for s in result.get("existingSquads", [])):
        raise UsersBackupError("Целевая Internal Squad не найдена; импорт отменён")
    if result["eligibleCount"] <= 0:
        print("Нет новых пользователей. База не изменена.")
        return
    output = psql(build_import_sql(data["payload"], squad_uuid))
    report_line = next((line for line in reversed(output.splitlines())
                        if line.lstrip().startswith("{")), None)
    try:
        if report_line is None:
            raise ValueError("JSON report was not returned")
        report = json.loads(report_line)
    except (ValueError, json.JSONDecodeError) as exc:
        raise UsersBackupError(
            "Импорт завершился без ошибки PostgreSQL, но итоговый JSON-отчёт не найден"
        ) from exc
    print("Импорт завершён:")
    for key, value in report.items():
        print(f"  {key}: {value}")
    print(f"Пропущено конфликтов: {len(result['conflicts'])}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Remnawave Users-only Backup & Restore")
    sub = parser.add_subparsers(dest="command", required=True)
    exp = sub.add_parser("export")
    exp.add_argument("--output", required=True, type=Path)
    prev = sub.add_parser("preview")
    prev.add_argument("--input", required=True, type=Path)
    prev.add_argument("--squad-uuid")
    sub.add_parser("squads")
    imp = sub.add_parser("import")
    imp.add_argument("--input", required=True, type=Path)
    imp.add_argument("--squad-uuid", required=True)
    imp.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "export":
            write_archive(args.output)
        elif args.command == "preview":
            show_preview(args.input, args.squad_uuid)
        elif args.command == "squads":
            list_squads()
        elif args.command == "import":
            import_archive(args.input, args.squad_uuid, args.apply)
        return 0
    except UsersBackupError as exc:
        print(f"ОШИБКА: {exc}", file=sys.stderr)
        return 1
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"ОШИБКА: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
