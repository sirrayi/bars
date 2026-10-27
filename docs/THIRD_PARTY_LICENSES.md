---
summary: "Bundled open-source notices and how to refresh their pinned sources."
read_when:
  - Auditing bundled third-party resources and their licenses
  - Updating SwiftPM dependencies
---

# Third-party notices

Settings → About → Acknowledgements displays the full notices bundled in
`Sources/BarsCore/Resources/Acknowledgements.json`. This generated resource ships with the app,
widget and CLI.

Refresh notices after changing either root or widget `Package.resolved`:

```sh
python3 Scripts/acknowledgements.py --write
python3 Scripts/acknowledgements.py --verify-upstream
```

The generator reads immutable revisions from both lockfiles, retrieves exact LICENSE and NOTICE files,
and keeps their text and SHA-256 hashes.

`make check` checks both lockfiles, required notices and source-text hashes without network access.
Adding a SwiftPM dependency requires adding its license source to the generator.
`--verify-upstream` additionally regenerates and compares all text against upstream sources.

To inspect the exact plaintext:

```sh
python3 Scripts/acknowledgements.py --text-output /tmp/THIRD_PARTY_NOTICES
```
