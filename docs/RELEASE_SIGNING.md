# Release signing

Official release keys must never be committed to this repository.

Contributor builds use the Android debug key from their own Android SDK setup.
Official builds should provide a dedicated release keystore through environment
variables or a local, ignored `key.properties` file.

Suggested variables:

```text
VITALOOP_KEYSTORE=/absolute/path/to/release.keystore
VITALOOP_KEYSTORE_PASSWORD
VITALOOP_KEY_ALIAS
VITALOOP_KEY_PASSWORD
```

Do not put values in README files, CI YAML, issues, pull requests, screenshots, or
shell history.

Verify a release artifact with:

```bash
apksigner verify --verbose --print-certs app-release.apk
sha256sum app-release.apk
```

The in-app updater verifies package name, increasing version code, and the signing
certificate against the installed app. Public builds should either disable the
self-update feature or require a user-controlled update manifest signed with the
same key.
