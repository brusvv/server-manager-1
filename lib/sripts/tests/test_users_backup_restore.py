#!/usr/bin/env python3
"""Offline tests for Users-only archive validation and SQL safety."""
import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "panel" / "py" / "users_backup.py"
SPEC = importlib.util.spec_from_file_location("users_backup", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def sample_payload():
    return {
        "format": MODULE.FORMAT, "formatVersion": MODULE.FORMAT_VERSION,
        "exportedAt": "2026-11-17T00:00:00Z",
        "users": [{
            "sourceId": "42",
            "user": {
                "short_uuid": "abc123", "username": "test-user", "status": "ACTIVE",
                "expire_at": "2027-01-01T00:00:00", "trojan_password": "secret",
                "vless_uuid": "12345678-1234-1234-1234-123456789abc",
                "ss_password": "password",
                "external_squad_uuid": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            },
            "traffic": {
                "used_traffic_bytes": 100, "lifetime_used_traffic_bytes": 500,
                "last_connected_node_uuid": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                "first_connected_at": "2026-01-01T00:00:00",
            },
            "meta": {"metadata": {"source": "test"}},
            "devices": [{
                "hwid": "0123456789abcdef", "platform": "linux",
                "created_at": "2026-01-01T00:00:00",
                "updated_at": "2026-01-01T00:00:00",
            }],
        }],
    }


class UsersBackupTests(unittest.TestCase):
    def archive(self, path, payload, checksum=None):
        content = json.dumps(payload, separators=(",", ":")).encode()
        manifest = {"format": MODULE.FORMAT, "formatVersion": MODULE.FORMAT_VERSION,
                    "usersCount": len(payload["users"]),
                    "payloadSha256": checksum or hashlib.sha256(content).hexdigest()}
        with zipfile.ZipFile(path, "w") as zf:
            zf.writestr("manifest.json", json.dumps(manifest))
            zf.writestr("users.json", content)

    def test_archive_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "valid.rwusers"
            self.archive(path, sample_payload())
            self.assertEqual(len(MODULE.load_archive(path)["payload"]["users"]), 1)

    def test_bad_checksum_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.rwusers"
            self.archive(path, sample_payload(), "0" * 64)
            with self.assertRaises(MODULE.UsersBackupError):
                MODULE.load_archive(path)

    def test_duplicate_identity_rejected(self):
        users = sample_payload()["users"]
        users.append(dict(users[0]))
        with self.assertRaises(MODULE.UsersBackupError):
            MODULE.validate_users(users)

    def test_import_is_add_only_and_remaps_ids(self):
        sql = MODULE.build_import_sql(sample_payload(), "cccccccc-cccc-cccc-cccc-cccccccccccc")
        self.assertIn("ON CONFLICT DO NOTHING", sql)
        self.assertIn("RETURNING id,username", sql)
        self.assertIn("INSERT INTO _users_map", sql)
        self.assertIn("INSERT INTO public.internal_squad_members", sql)
        self.assertIn("NULL,NULL,t.first_connected_at", sql.replace(" ", "").replace("\n", ""))
        self.assertNotIn("INSERT INTO public.nodes", sql)
        self.assertNotIn("INSERT INTO public.config_profiles", sql)
        self.assertNotIn("INSERT INTO public.internal_squads", sql)
        self.assertNotIn("INSERT INTO public.nodes_user_usage_history", sql)

    def test_preflight_checks_unique_fields(self):
        sql = MODULE._payload_sql(sample_payload())
        self.assertIn("e.username", sql)
        self.assertIn("e.short_uuid", sql)
        self.assertIn("e.vless_uuid", sql)
        self.assertIn("jsonb_array_elements", sql)


if __name__ == "__main__":
    unittest.main(verbosity=2)
