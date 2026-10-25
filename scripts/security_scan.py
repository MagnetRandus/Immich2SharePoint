#!/usr/bin/env python3
"""Conservative local/CI privacy check for a public source-only repository.

Scans staged Git blobs (not only files on disk), even with git add -f.
Cannot guarantee that every item of personal information will be detected.
Never prints matched credential values.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import PurePosixPath

MAX_BYTES = 512 * 1024
BLOCKED_SUFFIXES = {
    ".jpg", ".jpeg", ".jpe", ".png", ".heic", ".heif", ".gif",
    ".webp", ".tif", ".tiff", ".bmp", ".raw", ".dng", ".cr2",
    ".nef", ".arw", ".mp4", ".mov", ".m4v", ".avi", ".mkv",
    ".3gp", ".mp3", ".wav", ".flac", ".aac", ".exif", ".xmp",
    ".aae", ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt",
    ".pptx", ".csv", ".tsv", ".jsonl", ".ndjson", ".zip",
    ".rar", ".7z", ".tar", ".gz", ".zst", ".db", ".sqlite",
    ".sqlite3", ".dump", ".backup", ".bak", ".pfx", ".p12",
    ".pem", ".key", ".p8", ".jks", ".kdbx", ".log", ".env",
}
BLOCKED_PARTS = {
    "secrets", "secret", "credentials", "private", "personal",
    "real-data", "private-data", "exports", "backups", "photos",
    "videos", "originals", "media", "immich-library", "immich-data",
    "sharepoint-exports", "database-dumps", "discovery-reports",
    "inventories", ".ssh", ".aws", ".azure", ".venv",
    "node_modules", ".codex",
}
ALLOWED_SUFFIXES = {
    ".py", ".pyi", ".sh", ".ps1", ".psm1", ".psd1", ".md",
    ".txt", ".toml", ".yaml", ".yml", ".json", ".xml",
    ".html", ".css", ".js", ".jsx", ".ts", ".tsx",
    ".gitignore", ".gitattributes", ".editorconfig", ".cfg",
    ".ini", ".sql",
}
ALLOWED_EXACT = {
    ".gitignore", ".gitattributes", ".editorconfig",
    "LICENSE", ".githooks/pre-commit",
}
SUSPICIOUS_NAMES = (
    "client_secret", "service_account", "service-account",
    "credentials", "password", "api-key", "api_key",
    "access_token", "refresh_token", "private_key",
    "id_rsa", "id_ed25519",
)
PATTERNS = [
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})")),
    ("AWS key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("bearer token", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/-]{24,}", re.I)),
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{24,}\.eyJ[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{16,}\b")),
    ("hard-coded credential", re.compile(
        r"""(?i)\b(?:password|passwd|client_secret|api_key|access_token|refresh_token)\b\s*[:=]\s*["'](?!example|placeholder|dummy|changeme|not-a-real)[^"'\r\n]{8,}["']"""
    )),
    ("email address", re.compile(
        r"\b[A-Za-z0-9._%+-]+@(?!example\.(?:com|org|net)\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", re.I
    )),
    ("SharePoint site URL", re.compile(
        r"https?://[a-z0-9-]+\.sharepoint\.com/(?:sites|teams)/[a-z0-9%_-]+", re.I
    )),
    ("local home path", re.compile(
        r"(?:/home/[a-z0-9._-]+/|C:\\Users\\[A-Za-z0-9._ -]+\\)", re.I
    )),
    ("private IP", re.compile(
        r"\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3})\b"
    )),
    ("database export", re.compile(
        r"(?im)^\s*(?:COPY\s+[A-Za-z_][\w.]*\s*\(|INSERT\s+INTO\s+[A-Za-z_][\w.]*)"
    )),
]


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args], stderr=subprocess.PIPE)


def get_paths(mode: str) -> list[str]:
    if mode == "staged":
        raw = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
    else:
        raw = git("ls-files", "--cached", "-z")
    return [p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p]


def check(path: str) -> list[str]:
    issues: list[str] = []
    posix = PurePosixPath(path)
    name = posix.name.lower()
    parts = {part.lower() for part in posix.parts}
    if parts & BLOCKED_PARTS:
        issues.append("private-data directory")
    if name.startswith(".env") or name.endswith(
        (".local.json", ".local.yaml", ".local.yml", ".local.toml")
    ):
        issues.append("environment or local settings")
    if any(term in name for term in SUSPICIOUS_NAMES):
        issues.append("credential-like filename")
    if posix.suffix.lower() in BLOCKED_SUFFIXES:
        issues.append("media, data, archive or credential file")
    if posix.suffix.lower() not in ALLOWED_SUFFIXES and path not in ALLOWED_EXACT:
        issues.append("unapproved file type")
    if name.endswith(".json") and not (
        name in {"package.json", "tsconfig.json", "settings.example.json"}
        or name.endswith((".schema.json", ".example.json", ".synthetic.json"))
        or path.lower().startswith("tests/fixtures/synthetic/")
    ):
        issues.append("unapproved JSON data file")
    try:
        data = git("show", ":" + path)
    except subprocess.CalledProcessError:
        return issues + ["could not read staged blob"]
    if len(data) > MAX_BYTES:
        issues.append("larger than 512 KiB")
    if b"\0" in data:
        issues.append("binary content")
    try:
        content = data.decode("utf-8")
    except UnicodeDecodeError:
        return issues + ["not UTF-8 text"]
    for lineno, line in enumerate(content.splitlines(), 1):
        for label, pattern in PATTERNS:
            if pattern.search(line):
                issues.append(f"line {lineno}: {label}")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--staged", action="store_true")
    group.add_argument("--tracked", action="store_true")
    mode = "staged" if parser.parse_args().staged else "tracked"
    try:
        paths = get_paths(mode)
    except (OSError, subprocess.CalledProcessError):
        print("Security scan could not inspect Git index.", file=sys.stderr)
        return 1
    failed = False
    for path in paths:
        issues = check(path)
        if issues:
            failed = True
            print(f"BLOCKED: {path}", file=sys.stderr)
            for issue in sorted(set(issues)):
                print(f"  - {issue}", file=sys.stderr)
    if failed:
        print("Remove sensitive material and review staged changes.", file=sys.stderr)
        return 1
    print(f"Security scan passed: {len(paths)} {mode} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
