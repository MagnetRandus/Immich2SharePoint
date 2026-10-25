"""Tests for configuration loading using wholly invented settings."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from immich2sharepoint.config import ConfigError, load_config  # noqa: E402


def synthetic_config() -> dict[str, object]:
    return {
        "immich": {
            "base_url": "https://photos.example.invalid/",
            "api_key": "synthetic-api-secret-12345",
        },
        "sharepoint": {
            "site_url": "https://documents.example.invalid/sites/synthetic/",
            "tenant_id": "11111111-1111-4111-8111-111111111111",
            "client_id": "22222222-2222-4222-8222-222222222222",
            "client_secret": "synthetic-client-secret-67890",
            "photos_library": "Synthetic Photos",
            "metadata_list": "Synthetic Photo Metadata",
        },
    }


class ConfigTestCase(unittest.TestCase):
    def load(self, data: object):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic-config.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            return load_config(path)

    def test_loads_complete_configuration(self) -> None:
        config = self.load(synthetic_config())
        self.assertEqual(config.immich.base_url, "https://photos.example.invalid")
        self.assertEqual(config.sharepoint.photos_library, "Synthetic Photos")

    def test_reports_missing_setting_without_other_values(self) -> None:
        data = synthetic_config()
        secret = data["immich"].pop("api_key")  # type: ignore[union-attr]
        with self.assertRaisesRegex(ConfigError, "immich.api_key") as raised:
            self.load(data)
        self.assertNotIn(str(secret), str(raised.exception))

    def test_rejects_invalid_url_without_echoing_it(self) -> None:
        data = synthetic_config()
        invalid = "synthetic-secret-value-without-a-host"
        data["sharepoint"]["site_url"] = invalid  # type: ignore[index]
        with self.assertRaisesRegex(ConfigError, "sharepoint.site_url") as raised:
            self.load(data)
        self.assertNotIn(invalid, str(raised.exception))

    def test_rejects_invalid_json_without_echoing_content(self) -> None:
        marker = "synthetic-sensitive-marker"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "broken.json"
            path.write_text('{"immich": "' + marker, encoding="utf-8")
            with self.assertRaises(ConfigError) as raised:
                load_config(path)
        self.assertNotIn(marker, str(raised.exception))

    def test_all_values_are_excluded_from_representations(self) -> None:
        config = self.load(synthetic_config())
        rendered = repr(config)
        for section in synthetic_config().values():
            for value in section.values():  # type: ignore[union-attr]
                self.assertNotIn(str(value).rstrip("/"), rendered)

    def test_rejects_url_containing_credentials_without_echoing_it(self) -> None:
        data = synthetic_config()
        unsafe = "https://synthetic-user:synthetic-pass@localhost"
        data["immich"]["base_url"] = unsafe  # type: ignore[index]
        with self.assertRaisesRegex(ConfigError, "immich.base_url") as raised:
            self.load(data)
        self.assertNotIn(unsafe, str(raised.exception))

    def test_rejects_url_query_without_echoing_it(self) -> None:
        data = synthetic_config()
        unsafe = "https://example.invalid/?token=synthetic-secret"
        data["immich"]["base_url"] = unsafe  # type: ignore[index]
        with self.assertRaisesRegex(ConfigError, "immich.base_url") as raised:
            self.load(data)
        self.assertNotIn(unsafe, str(raised.exception))

    def test_missing_file_error_does_not_reveal_path(self) -> None:
        marker = "synthetic-sensitive-directory-name"
        with self.assertRaises(ConfigError) as raised:
            load_config(Path(marker) / "missing.json")
        self.assertNotIn(marker, str(raised.exception))


if __name__ == "__main__":
    unittest.main()
