# Instructions for Codex and other coding agents

## Project purpose
Build a read-only Immich source exporter to SharePoint Online. Develop on the
developer workstation; deploy only after review to the Linux Immich host.

## Mandatory privacy boundaries
- Treat this GitHub repository as PUBLIC and source-code-only.
- NEVER commit real photographs, videos, thumbnails, metadata, album information,
  GPS, names, passwords, tokens, certificates, private URLs, local account or
  machine paths, diagnostic logs, or real Immich/SharePoint payloads.
- NEVER copy the actual Immich discovery report into the repository.
- Use completely invented synthetic test data; do not sanitize real exports.
- Keep credentials outside Git. Provide configuration templates with placeholders.
- Inspect staged changes and run the security scanner before every commit:
  python3 scripts/security_scan.py --staged
- Do not bypass Git hooks, scanners or CI to make a commit pass. Address findings.
- Never print or store credentials or sensitive metadata in CI output or logs.

## Preserve production systems
- Keep the Immich server, Docker setup, databases, media tree and unrelated host
  services unchanged until an explicit deployment step is approved.
- Read originals with read-only file access. Never update EXIF, timestamps,
  xattrs, names or byte contents.
- Do not run installation, service restart, reconfiguration or destructive
  commands on the Immich host as part of development.
- No real SharePoint upload or other side effects without explicit approval.

## Data architecture
- Exactly two SharePoint artifacts: (1) one Photos document library for
  byte-for-byte original files, and (2) one Photo Metadata list for all
  available flattened metadata and provenance.
- No extra SharePoint lists/libraries, sidecar files or list attachments.
- Preserve full metadata with namespace/provenance distinctions, subject to
  validated SharePoint limits; flag overflow rather than silently dropping it.
- Identify source assets by Immich ID and original bytes by SHA-256.
- Avoid duplicate uploads; never silently overwrite archived original media.
- Metadata-only changes should update list items, not re-upload the file.
- Make operations resumable, testable and idempotent; dry-run by default.

## Engineering workflow
- Design and test on the development workstation with synthetic fixtures first.
- Separate provisioner, extractor, sync service, and test suites.
- Prefer simple Python tooling for extraction/sync and PnP.PowerShell for
  provisioning; use Graph/SharePoint API as appropriate.
- Add automated tests for byte identity, duplicate handling, metadata overflow,
  retries, partial failure, and checkpoint recovery.
- Do not commit generated assets or deploy from CI.
