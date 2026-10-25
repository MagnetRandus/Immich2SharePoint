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
