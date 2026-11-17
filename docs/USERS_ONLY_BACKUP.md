# Remnawave Users-only Backup / Restore

This transfer mode is separate from the existing full Panel/stack backup and
restore paths. It exports user account data without copying source
infrastructure configuration.

## Included

- users: username, short UUID, VLESS UUID, Trojan/SS credentials, status,
  expiry, traffic limits/reset settings, descriptions, tags, Telegram ID,
  email, HWID limit, threshold state, and timestamps.
- user_traffic: current and lifetime counters and first-connected time.
  online_at and last_connected_node_uuid are cleared at import because they
  describe live state and source nodes.
- user_meta: user metadata JSON.
- hwid_user_devices: registered HWID devices.

## Excluded

Nodes and node-specific history/reports, Config Profiles, Inbounds, Hosts,
API tokens, certificates/keys, External/Internal Squad definitions,
subscription-request history, Docker configuration, .env, and Redis state.
Source external_squad_uuid is not copied because it refers to configuration
on the source panel. nodes_user_usage_history is excluded so node history is
not attached to unrelated target nodes.

## Workflow

1. Source panel: Перенос -> Users-only Backup / Restore -> Export.
2. Transfer the .rwusers archive over a secure channel.
3. Target panel: Перенос -> Users-only Backup / Restore -> Import.
4. Review preflight conflicts, select an existing target Internal Squad, type
   IMPORT, and apply.
5. Verify a sample user's profile and subscription.

The archive is a ZIP with manifest.json, users.json, and a SHA-256 checksum.
It contains credentials and must be protected like a password database.
Exports use mode 0600; do not place them on public or unencrypted file shares.

## Import semantics

- Add-only: no existing user is updated or deleted.
- Skip an account if username, short UUID, or VLESS UUID already exists.
- PostgreSQL generates new target numeric IDs; linked user rows use an explicit
  source-to-target ID map.
- New users are added to the operator-selected existing target Internal Squad.
  The target squad and its inbound configuration are never modified.
- Traffic counters, user metadata, and HWID devices are restored.
- Source External Squad mapping and node-bound live/history data are not restored.
- Import is one PostgreSQL transaction and rolls back on SQL failure.

The importer checks the required target schema before writing and rejects
unknown archive format versions.
