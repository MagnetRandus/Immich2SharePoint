# Immich2SharePoint

A read-only Immich source exporter for archiving original media and its metadata
in SharePoint Online. The project is in its initial development phase and does
not yet connect to either service.

## Local development configuration

Copy `config.example.json` to `config.local.json`, then replace every placeholder
with the appropriate local setting. `config.local.json` is Git-ignored and must
never be committed. The example values are entirely fictional and are not usable
credentials.

Protect the local file so only your user account can read it:

~~~sh
cp config.example.json config.local.json
chmod 600 config.local.json
~~~

Do not paste configuration contents into terminal output, issue reports, test
fixtures, logs, or diagnostics. Confirm the ignore rule before adding files:

~~~sh
git check-ignore -v config.local.json
~~~

The loader defaults to `config.local.json` but accepts an explicit path for tests
and tooling:

~~~python
from immich2sharepoint.config import load_config

config = load_config()
~~~

It reports missing or invalid setting names without including their values.

## Tests

The test suite uses only invented data and the Python standard library:

~~~sh
python3 -m unittest discover -s tests
python3 scripts/security_scan.py --tracked
~~~

## SharePoint provisioning on comfycrocs

Provisioning is performed manually with
[`provisioning/Provision-SharePoint.ps1`](provisioning/Provision-SharePoint.ps1).
It creates only the **Photos** document library and **Photo Metadata** list from
the reviewed schema. It never uploads media or metadata, deletes resources, or
changes an incompatible existing field.

Prerequisites on comfycrocs are PowerShell 7.4 or later, PnP.PowerShell, and an
approved Entra ID application with permission to manage lists on the target
site. Install and authentication setup are separate administrator-reviewed
steps; the repository does not install modules or contain credentials.

Keep the real site URL and Entra client ID outside Git, for example in protected
session environment variables. PnP.PowerShell requires a caller-owned client ID
for interactive authentication. First run the read-only default mode and review
every reported action:

~~~sh
pwsh ./provisioning/Provision-SharePoint.ps1 \
  -SiteUrl "$I2SP_SHAREPOINT_SITE_URL" \
  -ClientId "$ENTRAID_APP_ID"
~~~

For a headless session, add `-DeviceLogin`. Dry-run connects to read the existing
schema but makes no SharePoint changes. It reports compatible, missing, and
incompatible definitions without printing the site URL or credentials.

Only after reviewing the dry-run and receiving explicit deployment approval,
apply missing resources by adding `-Apply`:

~~~sh
pwsh ./provisioning/Provision-SharePoint.ps1 \
  -SiteUrl "$I2SP_SHAREPOINT_SITE_URL" \
  -ClientId "$ENTRAID_APP_ID" \
  -Apply
~~~

`-Apply` creates missing containers and columns. Existing incompatible settings
remain unchanged and stop the run for manual review. Never save real parameter
values, command output, or authentication material in the repository.
