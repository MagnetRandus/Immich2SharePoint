"""Load and validate local connection settings without exposing secrets."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import urlparse

DEFAULT_CONFIG_PATH = Path("config.local.json")


class ConfigError(ValueError):
    """A safe-to-display configuration error."""


@dataclass(frozen=True)
class ImmichConfig:
    base_url: str = field(repr=False)
    api_key: str = field(repr=False)


@dataclass(frozen=True)
class SharePointConfig:
    site_url: str = field(repr=False)
    tenant_id: str = field(repr=False)
    client_id: str = field(repr=False)
    client_secret: str = field(repr=False)
    photos_library: str = field(repr=False)
    metadata_list: str = field(repr=False)


@dataclass(frozen=True)
class AppConfig:
    immich: ImmichConfig
    sharepoint: SharePointConfig


def _object(value: Any, name: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError(f"Setting '{name}' must be an object.")
    return value


def _text(section: Mapping[str, Any], key: str, prefix: str) -> str:
    name = f"{prefix}.{key}"
    if key not in section:
        raise ConfigError(f"Missing required setting '{name}'.")
    value = section[key]
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"Setting '{name}' must be a non-empty string.")
    return value.strip()


def _url(section: Mapping[str, Any], key: str, prefix: str) -> str:
    name = f"{prefix}.{key}"
    value = _text(section, key, prefix)
    parsed = urlparse(value)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ConfigError(
            f"Setting '{name}' must be an absolute HTTP(S) URL without "
            "credentials, a query, or a fragment."
        )
    return value.rstrip("/")


def load_config(path: str | Path = DEFAULT_CONFIG_PATH) -> AppConfig:
    """Load a JSON configuration file and return validated immutable settings."""
    config_path = Path(path)
    try:
        with config_path.open(encoding="utf-8") as handle:
            raw = json.load(handle)
    except FileNotFoundError:
        raise ConfigError(
            "Configuration file not found. Create config.local.json from "
            "config.example.json and protect it with file permissions."
        ) from None
    except (OSError, UnicodeError):
        raise ConfigError("Configuration file could not be read.") from None
    except json.JSONDecodeError:
        raise ConfigError("Configuration file is not valid JSON.") from None

    root = _object(raw, "configuration")
    if "immich" not in root:
        raise ConfigError("Missing required setting 'immich'.")
    if "sharepoint" not in root:
        raise ConfigError("Missing required setting 'sharepoint'.")
    immich = _object(root["immich"], "immich")
    sharepoint = _object(root["sharepoint"], "sharepoint")

    return AppConfig(
        immich=ImmichConfig(
            base_url=_url(immich, "base_url", "immich"),
            api_key=_text(immich, "api_key", "immich"),
        ),
        sharepoint=SharePointConfig(
            site_url=_url(sharepoint, "site_url", "sharepoint"),
            tenant_id=_text(sharepoint, "tenant_id", "sharepoint"),
            client_id=_text(sharepoint, "client_id", "sharepoint"),
            client_secret=_text(sharepoint, "client_secret", "sharepoint"),
            photos_library=_text(sharepoint, "photos_library", "sharepoint"),
            metadata_list=_text(sharepoint, "metadata_list", "sharepoint"),
        ),
    )
