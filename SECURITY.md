# Privacy and repository security policy

This is a source-code repository. It may be public. Treat real photographs,
videos, GPS information, EXIF/IPTC/XMP metadata, filenames, albums, descriptions,
Immich responses and SharePoint records as personal/private information.

## Never commit

- Real family photos, videos, derivatives, thumbnails or screenshots.
- Immich discovery reports, raw API responses, database dumps, metadata,
  ExifTool output, album lists, server inventories, logs or backup files.
- API keys, tokens, certificates, passwords or any production settings.
- Real tenant URLs, account emails, local home paths or machine-specific details.
- Real data even when seemingly anonymized. Use invented synthetic test fixtures.

## One-time setup after cloning

Run these commands in the local repository:

~~~sh
git config --local core.hooksPath .githooks
python3 scripts/security_scan.py --tracked
~~~

Before every commit, inspect what is staged:

~~~sh
git diff --cached --name-status
python3 scripts/security_scan.py --staged
~~~

The local hook reads staged Git objects, including forcibly added files. The
GitHub Actions check examines all tracked files on push and pull requests.
Enable secret-scanning push protection and branch protection in GitHub
repository settings where available.

## Limitations

Ignore rules and the scanner provide defense in depth, not a guarantee:
personal data may evade pattern matching; local hooks can be bypassed; CI
executes AFTER data is uploaded. Human staged-diff review is mandatory. Keep
the repository private if real customer or personal information could be added.

## Incident response

If a secret or personal data reaches GitHub, stop pushing, revoke/rotate any
credentials, and assess exposure immediately. Deleting a file in a new commit
does not remove old Git history. Coordinate history cleanup and cache/fork
handling; assume public information may already have been copied.
